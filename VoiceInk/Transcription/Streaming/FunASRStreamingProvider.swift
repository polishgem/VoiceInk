import Foundation
import SwiftData
import os

/// FunASR streaming provider using native URLSessionWebSocketTask.
/// Connects to a self-hosted FunASR WebSocket server for real-time 2-pass transcription.
final class FunASRStreamingProvider: StreamingTranscriptionProvider {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FunASRStreamingProvider")
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private let modelContext: ModelContext

    /// Audio chunk buffering — FunASR expects chunks of `stride` bytes.
    /// stride = 60 * chunk_size[1] / chunk_interval / 1000 * sampleRate * 2
    /// With chunk_size=[5,10,5], chunk_interval=10, 16kHz: stride = 1920 bytes (60ms)
    private let stride = 1920
    private var audioBuffer = Data()
    private let bufferLock = NSLock()

    /// UserDefaults key for the FunASR server URL.
    static let serverURLKey = "FunASRServerURL"
    static let defaultServerURL = "ws://127.0.0.1:10095"

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        eventsContinuation?.finish()
    }

    // MARK: - StreamingTranscriptionProvider

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let serverURL = Self.resolvedServerURL()

        guard let url = URL(string: serverURL) else {
            throw StreamingTranscriptionError.connectionFailed("Invalid FunASR server URL: \(serverURL)")
        }

        let urlSession = URLSession(configuration: .default)
        self.session = urlSession

        let task = urlSession.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // Wait for the WebSocket handshake to complete
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Send initial configuration as text frame
        let config = buildConfig(language: language)
        let configData = try JSONSerialization.data(withJSONObject: config)
        let configString = String(data: configData, encoding: .utf8) ?? "{}"
        try await task.send(URLSessionWebSocketTask.Message.string(configString))

        // Start receiving messages
        startReceiveLoop()

        eventsContinuation?.yield(.sessionStarted)
        logger.notice("Connected to FunASR server: \(serverURL, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        // Buffer small chunks and send when we have a full stride
        bufferLock.lock()
        audioBuffer.append(data)

        while audioBuffer.count >= stride {
            let chunk = audioBuffer.prefix(stride)
            audioBuffer = audioBuffer.dropFirst(stride) as? Data ?? Data(audioBuffer.suffix(from: stride))
            bufferLock.unlock()
            try await task.send(URLSessionWebSocketTask.Message.data(Data(chunk)))
            bufferLock.lock()
        }
        bufferLock.unlock()
    }

    func commit() async throws {
        guard let task = webSocketTask else {
            throw StreamingTranscriptionError.notConnected
        }

        // Flush any remaining buffered audio (pad with silence to fill stride)
        bufferLock.lock()
        let remaining = audioBuffer
        audioBuffer = Data()
        bufferLock.unlock()

        if !remaining.isEmpty {
            var padded = remaining
            if padded.count < stride {
                padded.append(Data(count: stride - padded.count))
            }
            try await task.send(URLSessionWebSocketTask.Message.data(padded))
        }

        // Signal end of speech
        let endSignal = #"{"is_speaking": false}"#
        try await task.send(URLSessionWebSocketTask.Message.string(endSignal))

        // FunASR's offline pass triggers on next binary frame after is_speaking=false
        let triggerChunk = Data(count: stride)
        try await task.send(URLSessionWebSocketTask.Message.data(triggerChunk))
        logger.debug("Sent commit signal to FunASR")
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        eventsContinuation?.finish()
        logger.notice("Disconnected from FunASR server")
    }

    // MARK: - Private

    private func buildConfig(language: String?) -> [String: Any] {
        var config: [String: Any] = [
            "mode": "2pass",
            "chunk_size": [5, 10, 5],
            "chunk_interval": 10,
            "encoder_chunk_look_back": 4,
            "decoder_chunk_look_back": 0,
            "audio_fs": 16000,
            "wav_name": "voiceink",
            "is_speaking": true,
            "itn": true,
            "wav_format": "pcm"
        ]

        let hotwords = getHotwords()
        if !hotwords.isEmpty {
            config["hotwords"] = hotwords
        }

        return config
    }

    private func getHotwords() -> String {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let words = try? modelContext.fetch(descriptor), !words.isEmpty else {
            return ""
        }
        var dict: [String: Int] = [:]
        for word in words {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                dict[trimmed] = 20
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }

    private func startReceiveLoop() {
        guard let task = webSocketTask else { return }

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self = self else { break }
                    switch message {
                    case .string(let text):
                        self.handleServerMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleServerMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self = self, !Task.isCancelled else { break }
                    self.logger.error("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
                    self.eventsContinuation?.yield(.error(StreamingTranscriptionError.serverError(error.localizedDescription)))
                    break
                }
            }
        }
    }

    private func handleServerMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recognizedText = json["text"] as? String else {
            return
        }

        let mode = json["mode"] as? String ?? ""
        let isFinal = json["is_final"] as? Bool ?? false
        let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

        logger.debug("FunASR response: mode=\(mode, privacy: .public) text=\(trimmed, privacy: .public) is_final=\(isFinal)")

        switch mode {
        case "2pass-online", "online":
            if !trimmed.isEmpty {
                eventsContinuation?.yield(.partial(text: trimmed))
            }
        case "2pass-offline", "offline":
            // Always emit committed for offline results (even empty) to unblock waitForFinalCommit
            eventsContinuation?.yield(.committed(text: trimmed))
        default:
            if isFinal {
                eventsContinuation?.yield(.committed(text: trimmed))
            } else if !trimmed.isEmpty {
                eventsContinuation?.yield(.partial(text: trimmed))
            }
        }
    }

    // MARK: - Static Helpers

    static func resolvedServerURL() -> String {
        let stored = UserDefaults.standard.string(forKey: serverURLKey) ?? ""
        return stored.isEmpty ? defaultServerURL : stored
    }

    static func saveServerURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: serverURLKey)
    }
}
