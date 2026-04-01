# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Full build (first-time: clones whisper.cpp, builds XCFramework, then builds VoiceInk)
make all

# Local build without Apple Developer certificate (ad-hoc signing)
# Output: ~/Downloads/VoiceInk.app
make local

# Build and run
make dev

# Check prerequisites (git, xcodebuild, swift)
make check

# Clean build artifacts (removes ~/VoiceInk-Dependencies/)
make clean
```

The whisper.xcframework is built to `~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework`. This path is hardcoded in the Xcode project.

`make local` uses `LocalBuild.xcconfig` with ad-hoc signing and sets the `LOCAL_BUILD` Swift compilation flag. Local builds lack iCloud dictionary sync and auto-updates.

## Architecture

### Core Engine Flow

```
HotkeyManager → VoiceInkEngine.toggleRecord()
  → Recorder (CoreAudioRecorder: 48kHz → 16kHz mono PCM Int16)
    → TranscriptionSession (streaming or file-based)
      → TranscriptionPipeline: Transcribe → Filter → Format → WordReplace → PromptDetect → AIEnhance → Save → Paste
```

`VoiceInkEngine` is the main orchestrator (`@MainActor ObservableObject`). It manages recording state (`.idle` → `.recording` → `.transcribing` → `.enhancing` → `.idle`) and coordinates all subsystems.

### Multi-Provider Transcription System

`ModelProvider` enum defines 11 provider types: `.local`, `.parakeet`, `.groq`, `.elevenLabs`, `.deepgram`, `.mistral`, `.gemini`, `.soniox`, `.custom`, `.nativeApple`, `.funASR`.

Three key protocols:
- **`TranscriptionService`** — batch transcription interface (`transcribe(audioURL:model:)`)
- **`StreamingTranscriptionProvider`** — real-time WebSocket interface (`connect()`, `sendAudioChunk()`, `commit()`, `disconnect()`, `transcriptionEvents`)
- **`TranscriptionModel`** — unified model descriptor with `provider`, `name`, `supportedLanguages`

**`TranscriptionServiceRegistry`** routes models to services:
- Determines streaming vs batch capability per model
- Creates `StreamingTranscriptionSession` (with batch fallback) or `FileTranscriptionSession`
- Manages fallback models for streaming-only providers (e.g., Mistral realtime → voxtral-mini-latest)

### Adding a New Transcription Provider

1. Add case to `ModelProvider` enum (`TranscriptionModel.swift`)
2. Create provider implementing `StreamingTranscriptionProvider` or `TranscriptionService` (in `Transcription/Streaming/` or `Transcription/Batch/`)
3. Add model to `PredefinedModels.swift` as `CloudModel`
4. Register in `StreamingTranscriptionService.createProvider()` and `TranscriptionServiceRegistry.supportsStreaming()`
5. Add to `TranscriptionModelManager.usableModels` switch
6. Add to `ModelManagementView.filteredModels` cloud providers list
7. Add to `ModelCardRowView` provider routing and `CloudModelCardRowView.providerKey`

### Key Subsystems

- **PowerMode** (`PowerMode/`) — context-aware recording configs per app/URL, with auto-detection and per-mode AI enhancement
- **AI Enhancement** (`Services/AIEnhancement/`) — post-transcription AI rewriting via LLMkit
- **Dictionary** — user vocabulary stored as `VocabularyWord` in SwiftData; used as hotwords by streaming providers
- **Word Replacement** — regex-aware text substitution applied post-transcription

### Data Persistence

SwiftData models: `Transcription`, `VocabularyWord`, `WordReplacement`. Falls back to in-memory storage if file-based fails.

API keys stored in Keychain via `APIKeyManager` (provider keys mapped in `providerToKeychainKey` dictionary). Custom model API keys stored per model UUID.

40+ UserDefaults keys registered in `AppDefaults.swift`.

### State Management

`@StateObject` instances created in `VoiceInkApp` and injected via `@EnvironmentObject`:
- `VoiceInkEngine` — main orchestrator
- `WhisperModelManager` / `ParakeetModelManager` — local model lifecycle
- `TranscriptionModelManager` — model selection and usability
- `RecorderUIManager` — mini recorder visibility and positioning
- `HotkeyManager` — global hotkey handling

Shared singletons: `PowerModeManager.shared`, `SoundManager.shared`, `AudioCleanupManager.shared`.

## Dependencies

- **whisper.xcframework** — C++ whisper.cpp via FFI bridge (`LibWhisper.swift`)
- **FluidAudio** — Parakeet on-device ASR (SPM, pinned to `main` branch)
- **LLMkit** — AI enhancement and cloud streaming clients (SPM)
- **KeyboardShortcuts** — Global hotkey registration
- **Sparkle** — Auto-updates
- **LaunchAtLogin** — Login item persistence

## FunASR Integration

FunASR is a self-hosted real-time ASR provider using WebSocket, implemented in `Transcription/Streaming/FunASRStreamingProvider.swift`.

### Server Setup

```bash
# Start FunASR WebSocket server (requires funasr Python package)
python3 /path/to/FunASR/runtime/python/websocket/funasr_wss_server.py \
    --host 0.0.0.0 --port 10095 --device cpu --ngpu 0 --certfile "" --keyfile ""
```

Default models: Paraformer-large (offline) + Paraformer-large-online (streaming) + FSMN-VAD + CT-Transformer-Realtime (punctuation). All from ModelScope `iic/` org.

### WebSocket Protocol

FunASR uses a custom protocol, not a standard cloud API:

1. **Connect** to `ws://host:10095` (no subprotocol required)
2. **Send config JSON** (text frame): `{"mode": "2pass", "chunk_size": [5,10,5], "chunk_interval": 10, "audio_fs": 16000, "wav_name": "voiceink", "is_speaking": true, "itn": true, "wav_format": "pcm", "hotwords": "{...}"}`
3. **Stream PCM audio** (binary frames): 16kHz mono Int16 LE, buffered to 1920-byte stride (60ms chunks)
4. **End signal**: `{"is_speaking": false}` (text frame) + one empty binary frame to trigger offline pass
5. **Responses**: JSON with `mode` ("2pass-online" = partial, "2pass-offline" = final), `text`, `is_final`

### Key Implementation Details

- **Audio buffering**: VoiceInk sends ~340-byte chunks from CoreAudioRecorder; the provider accumulates them to 1920-byte stride before sending. Without buffering, FunASR's online model returns empty results.
- **Commit trigger**: FunASR's offline pass only triggers when a binary frame arrives after `is_speaking: false`. The provider sends a silent padding frame after the end signal.
- **Binary JSON fallback**: Apple's `URLSessionWebSocketTask` may send `.string()` messages as binary frames. The FunASR server was patched (in `funasr_wss_server.py`) to also parse JSON from binary messages (`messagejson(from binary)` handler before the audio processing section).
- **No API key**: FunASR is self-hosted. Server URL stored in UserDefaults (`FunASRServerURL`), defaults to `ws://127.0.0.1:10095`. `CloudModelCardRowView` shows a URL field instead of API key for `.funASR`.
- **Hotwords**: VoiceInk Dictionary words are sent as FunASR hotwords format `{"word": weight}` in the config JSON.
- **Always usable**: `TranscriptionModelManager.usableModels` returns `true` for `.funASR` (no API key check needed).

## Important Notes

- The Xcode project uses `fileSystemSynchronizedGroups` — new files in existing directories are auto-discovered without manual project file editing.
- `LOCAL_BUILD` compiler flag gates code paths that require entitlements (CloudKit, keychain groups). Check with `#if LOCAL_BUILD`.
- HTTP disk caching is disabled (`URLCache(memoryCapacity: 0, diskCapacity: 0)`) for API response privacy.
- FluidAudio (swift-tools-version: 6.0) may fail to compile on newer Xcode versions due to strict Swift 6 concurrency checks. Workaround: temporarily change its `Package.swift` to `swift-tools-version: 5.10` in the SourcePackages checkout.
