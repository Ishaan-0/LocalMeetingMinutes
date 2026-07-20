# MeetingMinutes — Implementation Plan

## Overview

A macOS menubar app that captures meeting audio in real-time, transcribes it locally with speaker labels, and exports structured minutes to Notion.

**Stack:** Pure Swift + SwiftUI. No Python, no Electron, no Node.js.

## Global Constraints

- macOS 14.0+ minimum, Apple Silicon primary target
- Swift 5.9+
- `LSUIElement = YES` — no dock icon, menubar only
- All ML inference runs locally (WhisperKit via Core ML + ANE, CoreML speaker embeddings)
- WhisperKit SPM: `https://github.com/argmaxinc/WhisperKit` (Argmax)
- Models downloaded on first launch, stored in `~/Library/Application Support/MeetingMinutes/Models/`, gitignored
- YAGNI: no feature flags, no backwards-compat shims, no speculative abstractions
- Tests for all logic-bearing code (services, merger, clustering)
- Commit after each task with a descriptive message

## File Structure

```
MeetingMinutes/
├── MeetingMinutes.xcodeproj
├── MeetingMinutes/
│   ├── App/
│   │   ├── MeetingMinutesApp.swift       # @main, NSStatusItem, NSPopover
│   │   └── AppState.swift                # @MainActor ObservableObject, all published state
│   ├── Audio/
│   │   ├── AudioCaptureManager.swift     # ScreenCaptureKit + AVAudioEngine, mixes both
│   │   └── AudioRingBuffer.swift         # Thread-safe circular buffer
│   ├── Transcription/
│   │   └── TranscriptionManager.swift    # WhisperKit wrapper, chunked inference
│   ├── Diarization/
│   │   ├── VoiceActivityDetector.swift   # RMS energy threshold
│   │   ├── SpeakerEmbeddingModel.swift   # CoreML ECAPA-TDNN wrapper
│   │   ├── AgglomerativeClustering.swift # Cosine distance + average linkage
│   │   └── SpeakerDiarizer.swift         # VAD → embedding → clustering → labels
│   ├── Merger/
│   │   └── SegmentMerger.swift           # Join Whisper segments with speaker labels
│   ├── Models/
│   │   ├── Session.swift                 # Codable session model
│   │   ├── TranscriptSegment.swift       # Whisper output segment
│   │   ├── MergedSegment.swift           # Segment with speaker label
│   │   └── SpeakerTurn.swift             # Diarization output
│   ├── Services/
│   │   ├── KeychainService.swift         # Store/retrieve Notion token
│   │   ├── SessionStore.swift            # Read/write sessions to disk
│   │   ├── OllamaService.swift           # HTTP summarization
│   │   ├── NotionService.swift           # Notion REST API export
│   │   └── ModelDownloadManager.swift    # Download + verify ML models
│   └── Views/
│       ├── MenuBarView.swift             # Status icon + popover root
│       ├── SetupView.swift               # Multi-step onboarding
│       ├── HomeView.swift                # Idle state + recent sessions
│       ├── RecordingView.swift           # Live transcript + controls
│       └── SummaryView.swift             # Post-session review + export
├── MeetingMinutesTests/
│   ├── SegmentMergerTests.swift
│   ├── AgglomerativeClusteringTests.swift
│   ├── OllamaServiceTests.swift
│   └── NotionServiceTests.swift
├── scripts/
│   └── convert_ecapa_tdnn.py             # One-time CoreML model conversion (not bundled)
├── build/
│   ├── icon.icns                         # App icon (macOS)
│   └── icon.png                          # Source PNG
├── docs/
│   └── plan.md                           # This file
└── README.md
```

## Pipeline Flow

```
ScreenCaptureKit (system audio) ─┐
                                  ├─► AudioCaptureManager ─► AudioRingBuffer
AVAudioEngine (microphone)      ─┘         (16kHz mono PCM)
                                                    │
                                                    ▼
                                      VoiceActivityDetector
                                        (RMS energy gate)
                                                    │ speech chunks
                                    ┌───────────────┤
                                    │               │
                                    ▼               ▼
                            WhisperKit      SpeakerEmbeddingModel
                         [{text,start,end}]   (CoreML ECAPA-TDNN)
                                    │               │
                                    │    AgglomerativeClustering
                                    │        (Accelerate vDSP)
                                    │               │
                                    └──► SegmentMerger ◄──┘
                                          [{speaker, text, start, end}]
                                                    │
                                      ┌─────────────┴──────────────┐
                                      ▼                            ▼
                               RecordingView              (end of session)
                              (live transcript)        OllamaService → summary
                                                               │
                                                       NotionService → export
```

---

## Tasks

### Task 1: Xcode project + Swift package setup

**Goal:** Runnable skeleton menubar app with correct configuration.

**Deliverables:**
- `MeetingMinutes.xcodeproj` targeting macOS 14.0
- `Info.plist`:
  - `LSUIElement = YES` (no dock icon)
  - `NSScreenCaptureUsageDescription`: "MeetingMinutes needs screen recording access to capture meeting audio."
  - `NSMicrophoneUsageDescription`: "MeetingMinutes needs microphone access for in-person meetings."
- `MeetingMinutes.entitlements`:
  - `com.apple.security.network.client = true`
  - `com.apple.security.device.microphone = true`
- WhisperKit added as SPM dependency: `https://github.com/argmaxinc/WhisperKit` (up-to-range 1.0.0)
- `MeetingMinutesApp.swift`: `@main`, `@NSApplicationDelegateAdaptor`, hides dock icon on launch
- `AppState.swift`: `@MainActor final class AppState: ObservableObject` with placeholder `@Published var phase: AppPhase = .setup`
- `AppPhase`: `enum AppPhase { case setup, home, recording, summary }`
- `MenuBarView.swift`: `NSStatusItem` showing a placeholder icon, `NSPopover` with a `Text("MeetingMinutes")` placeholder
- App launches, shows menubar icon, click opens popover — no crash

**Tests:** None (pure setup).

---

### Task 2: Audio capture manager

**Goal:** Capture system audio + microphone simultaneously, mix to 16kHz mono PCM, feed a ring buffer.

**Deliverables:**
- `AudioRingBuffer.swift`: thread-safe circular buffer backed by `[Float]`, capacity 10s at 16kHz (160,000 samples). Methods: `write(_ samples: [Float])`, `read(count: Int) -> [Float]?`
- `AudioCaptureManager.swift`:
  - `func start() async throws` — requests microphone permission, starts SCStream + AVAudioEngine
  - `func stop()` — stops both
  - `SCStreamConfiguration`: `capturesAudio = true`, `excludesCurrentProcessAudio = true`, `sampleRate = 16000`, `channelCount = 1`
  - `AVAudioEngine` mic: resample to 16kHz mono if needed using `AVAudioConverter`
  - Mix by summing both streams (clamp to [-1, 1])
  - Delivers 100ms chunks (1600 Float32 samples) via `AsyncStream<[Float]>` property `audioChunks`
- Permission error surfaces as thrown error with descriptive message

**Tests:** None (hardware-dependent; tested manually).

---

### Task 3: WhisperKit transcription

**Goal:** Transcribe audio chunks to timestamped text segments using WhisperKit.

**Deliverables:**
- `TranscriptSegment.swift`: `struct TranscriptSegment: Identifiable, Codable { let id: UUID; let text: String; let startTime: Float; let endTime: Float }`
- `TranscriptionManager.swift`:
  - `init()` — does not load model on init
  - `func loadModel(size: WhisperModelSize, progress: @escaping (Double) -> Void) async throws` — loads from `~/Library/Application Support/MeetingMinutes/Models/<size>/`
  - `func transcribe(samples: [Float]) async throws -> [TranscriptSegment]` — calls WhisperKit, maps to `TranscriptSegment`
  - Buffers incoming chunks into 5-second windows before transcribing (reduces overhead)
  - `enum WhisperModelSize: String, CaseIterable { case small = "whisper-small", case medium = "whisper-medium" }`

**Tests:** None (model-dependent; tested via integration in Task 10).

---

### Task 4: Speaker diarization

**Goal:** Identify which speaker said which audio segment using CoreML embeddings + clustering.

**Deliverables:**
- `SpeakerTurn.swift`: `struct SpeakerTurn: Codable { let speakerLabel: String; let startTime: Float; let endTime: Float }`
- `VoiceActivityDetector.swift`:
  - `func isSpeech(samples: [Float]) -> Bool` — returns true if RMS energy > 0.01
  - `func splitIntoSpeechSegments(samples: [Float], sampleRate: Int) -> [(start: Int, end: Int)]` — groups consecutive speech frames (100ms each) separated by silence gaps < 500ms
- `SpeakerEmbeddingModel.swift`:
  - Wraps a CoreML `.mlmodel` file at `~/Library/Application Support/MeetingMinutes/Models/speaker-embedding.mlmodel`
  - Input: `[Float]` raw audio samples for one speech segment
  - Internally computes 80-dim mel filterbank features using `vDSP` from Accelerate
  - Output: `[Float]` 192-dim L2-normalized embedding vector
  - `func embed(samples: [Float]) throws -> [Float]`
- `AgglomerativeClustering.swift`:
  - `func cluster(embeddings: [[Float]], threshold: Float = 0.7) -> [Int]` — returns speaker index per embedding
  - Uses cosine distance, average linkage
  - Implemented with `vDSP` dot products from Accelerate
- `SpeakerDiarizer.swift`:
  - `func diarize(samples: [Float], sampleRate: Int, offsetSeconds: Float) -> [SpeakerTurn]`
  - Splits by VAD → embeds each segment → clusters → returns `[SpeakerTurn]` with friendly labels "Speaker 1", "Speaker 2", etc.
  - Maintains speaker map across calls (same cluster index = same label across the session)
- `scripts/convert_ecapa_tdnn.py`: Python script using `speechbrain` + `coremltools` to export ECAPA-TDNN to `.mlmodel`. Outputs `speaker-embedding.mlmodel`. Includes SHA256 of the output model.

**Tests:**
- `AgglomerativeClusteringTests.swift`:
  - Identical embeddings cluster together
  - Orthogonal embeddings cluster separately (threshold 0.7)
  - Single embedding returns one cluster

---

### Task 5: Segment merger

**Goal:** Combine WhisperKit transcript segments with diarization speaker turns to produce attributed transcript.

**Deliverables:**
- `MergedSegment.swift`: `struct MergedSegment: Identifiable, Codable { let id: UUID; let speakerLabel: String; let text: String; let startTime: Float; let endTime: Float }`
- `SegmentMerger.swift`:
  - `func merge(transcriptSegments: [TranscriptSegment], speakerTurns: [SpeakerTurn]) -> [MergedSegment]`
  - Assigns speaker by midpoint: find the `SpeakerTurn` whose `[start, end)` contains `(segment.startTime + segment.endTime) / 2`
  - Falls back to `"Speaker 1"` when no turn covers the midpoint
  - Each `TranscriptSegment` produces exactly one `MergedSegment`

**Tests (`SegmentMergerTests.swift`):**
- Single segment with no speaker turns → label is "Speaker 1"
- Segment midpoint falls within a speaker turn → correct label assigned
- Segment midpoint outside all turns → falls back to "Speaker 1"
- Two segments in different speaker turns → different labels
- Same speaker appears in two turns → same label both times

---

### Task 6: Keychain + session store

**Goal:** Persist Notion token securely and save/load session data to disk.

**Deliverables:**
- `Session.swift`:
  ```swift
  struct Session: Identifiable, Codable {
      let id: UUID
      var title: String           // e.g. "Meeting – Jul 20, 2026"
      let date: Date
      var duration: TimeInterval
      var segments: [MergedSegment]
      var summary: String?
      var takeaways: [String]
      var actionItems: [ActionItem]
      var notionPageURL: String?
  }
  struct ActionItem: Identifiable, Codable {
      let id: UUID
      var text: String
      var isChecked: Bool
  }
  ```
- `KeychainService.swift`:
  - `func saveNotionToken(_ token: String) throws`
  - `func loadNotionToken() throws -> String?`
  - `func deleteNotionToken() throws`
  - Service name: `"com.meetingminutes.notion-token"`, account: `"notion"`
- `SessionStore.swift`:
  - Stores sessions at `~/Library/Application Support/MeetingMinutes/sessions/<id>.json`
  - `func save(_ session: Session) throws`
  - `func load(id: UUID) throws -> Session`
  - `func loadAll() throws -> [Session]` — sorted by date descending
  - `func delete(id: UUID) throws`

**Tests:** None (file I/O; tested via integration).

---

### Task 7: Ollama service

**Goal:** Check Ollama availability and generate meeting summary.

**Deliverables:**
- `OllamaService.swift`:
  - `func ping() async -> Bool` — GET `http://localhost:11434/api/tags`, returns true if 200
  - `func summarize(transcript: String, model: String) async throws -> SummaryResult`
    - POST `http://localhost:11434/api/generate`, `stream: false`
    - Prompt template instructs model to return only valid JSON: `{"takeaways": [...], "action_points": [...]}`
    - Strips markdown fences before JSON parse
    - 120s timeout
  - `struct SummaryResult: Decodable { let takeaways: [String]; let actionPoints: [String] }`
  - `struct OllamaError: LocalizedError` — wraps HTTP errors and JSON parse failures; parse errors include "parse" in `errorDescription`
- `OllamaServiceTests.swift` (mock `URLProtocol`):
  - Parses valid JSON response correctly
  - Throws on HTTP error status
  - Throws with "parse" in message on malformed JSON

---

### Task 8: Notion service

**Goal:** Export session to a Notion database as a structured page.

**Deliverables:**
- `NotionService.swift`:
  - `init(token: String)`
  - `func validateToken() async throws` — GET `https://api.notion.com/v1/users/me`, throws descriptive `NotionError` on failure
  - `func ensureDatabaseExists(parentPageURL: String) async throws -> String`
    - Parses page ID from URL (last path component, strip dashes)
    - POST `/v1/databases` with schema:
      - `Name` (title), `Date` (date), `Duration` (rich_text), `Participants` (multi_select), `Status` (select: options "Draft", "Reviewed")
    - Stores returned database ID in `UserDefaults` key `"notion_database_id"`
    - Returns database ID
    - If `UserDefaults` already has a database ID, returns it without re-creating
  - `func exportSession(_ session: Session, databaseId: String) async throws -> String`
    - POST `/v1/pages` — creates page with:
      - Properties: Name = session title, Date = session date, Duration = formatted string, Participants = speaker labels as multi_select, Status = "Draft"
      - Children blocks: H1 "Summary", bulleted list of takeaways, H2 "Action Items", to_do blocks per action item, H2 "Transcript", toggle block containing all `MergedSegment` lines as `"{speakerLabel}: {text}"`
    - Returns the `url` field from the response
  - Notion API version header: `"2022-06-28"`
  - `struct NotionError: LocalizedError`
- `NotionServiceTests.swift` (mock `URLProtocol`):
  - `validateToken` returns without throwing on 200
  - `validateToken` throws `NotionError` on 401
  - `exportSession` returns URL string on success
  - `exportSession` throws on HTTP error

---

### Task 9: Model download manager

**Goal:** Download Whisper Core ML models and speaker embedding model on first launch with progress reporting.

**Deliverables:**
- `ModelDownloadManager.swift`:
  - `enum WhisperModelSize: String, CaseIterable, Identifiable { case small, medium }`
    - `var displayName: String` — "Small (~100 MB)" or "Medium (~400 MB)"
    - `var downloadURL: URL` — points to Argmax's hosted WhisperKit model URLs
    - `var sha256: String` — hardcoded expected checksum
  - `static let speakerModelURL: URL` — ECAPA-TDNN CoreML model download URL
  - `static let speakerModelSHA256: String`
  - `func downloadWhisperModel(_ size: WhisperModelSize, progress: @escaping (Double) -> Void) async throws`
    - Downloads to temp file, verifies SHA256, moves to `~/Library/.../Models/<size>/`
    - Skips download if destination already exists and checksum matches
  - `func downloadSpeakerModel(progress: @escaping (Double) -> Void) async throws`
    - Same pattern, destination: `~/Library/.../Models/speaker-embedding.mlmodel`
  - `func isWhisperModelReady(_ size: WhisperModelSize) -> Bool`
  - `func isSpeakerModelReady() -> Bool`
  - `private func sha256(of url: URL) throws -> String` — uses `CryptoKit`

**Tests:** None (network-dependent; tested manually in setup flow).

---

### Task 10: AppState + session coordinator

**Goal:** Wire all components into a single observable state object that drives the UI.

**Deliverables:**
- `AppState.swift` (`@MainActor final class AppState: ObservableObject`):
  - `@Published var phase: AppPhase`
  - `@Published var liveSegments: [MergedSegment]`
  - `@Published var currentSession: Session?`
  - `@Published var recentSessions: [Session]`
  - `@Published var ollamaAvailable: Bool`
  - `@Published var isExporting: Bool`
  - `@Published var exportError: String?`
  - `let sessionStore: SessionStore`
  - `let keychainService: KeychainService`
  - `let ollamaService: OllamaService`
  - `let notionService: NotionService?` — nil until token set
  - Private: `audioCaptureManager`, `transcriptionManager`, `speakerDiarizer`, `segmentMerger`
  - `func startRecording(whisperModelSize: WhisperModelSize) async throws`:
    1. Start `AudioCaptureManager`
    2. For each 5s chunk from `audioChunks`: transcribe + diarize concurrently using `async let`, merge, append to `liveSegments`
    3. Every 30s of accumulated audio: run full diarization pass to correct early speaker assignments
    4. Switch `phase` to `.recording`
  - `func stopRecording() async throws`:
    1. Stop `AudioCaptureManager`
    2. Flush remaining audio
    3. Build `Session` from `liveSegments`
    4. Save to `SessionStore`
    5. If Ollama available: call `OllamaService.summarize`, update session
    6. Switch `phase` to `.summary`
  - `func exportToNotion() async`:
    1. Set `isExporting = true`
    2. Ensure database exists, export session, update `currentSession.notionPageURL`, save
    3. Set `isExporting = false`
  - `func checkOllama() async` — updates `ollamaAvailable`
  - `func loadRecentSessions()` — loads from `SessionStore`

**Tests:** None (integration; exercised via UI).

---

### Task 11: Setup screen

**Goal:** Multi-step onboarding that configures all required components before first use.

**Deliverables:**
- `SetupView.swift` — SwiftUI view presented when `phase == .setup`:
  - **Step 1 — Welcome + Permissions**:
    - App name, one-line description
    - Two permission rows: "Screen Recording" and "Microphone" each with a status badge and "Grant Access" button that calls `requestPermission()`
    - Continue button enabled when both granted
  - **Step 2 — Whisper Model**:
    - Explanation: "MeetingMinutes uses Whisper to transcribe speech locally on your Mac. No audio ever leaves your device."
    - Two option cards: Small (~100 MB, faster) and Medium (~400 MB, more accurate)
    - "Download" button → shows `ProgressView` with bytes/total, calls `ModelDownloadManager`
    - Continue enabled when download complete
  - **Step 3 — Ollama (optional)**:
    - Explanation of what Ollama provides (summary, action items)
    - Numbered steps:
      1. Download Ollama from ollama.ai (tappable link)
      2. Open Terminal and run: `ollama pull llama3.2:3b` (copyable code block)
      3. Ollama will run in the background automatically
    - "Check Ollama" button → calls `ollamaService.ping()`, shows green/red status
    - "Skip for now" + "Continue" (both always enabled — Ollama is optional)
  - **Step 4 — Notion**:
    - Explanation: "Connect Notion to automatically export meeting minutes to a structured dashboard."
    - Numbered steps with descriptive text (placeholder `Image` views for screenshots the user will provide):
      1. Go to `notion.so/profile/integrations` → click "New integration"
      2. Name it "MeetingMinutes", select your workspace → click Save
      3. Copy the "Internal Integration Secret" token
      4. In Notion, open the page where you want the dashboard → click ··· → Connections → add "MeetingMinutes"
      5. Copy the page URL
    - `SecureField` for token, `TextField` for page URL
    - "Validate" button → calls `NotionService.validateToken()`, shows result
    - "Complete Setup" button enabled when token validated
  - Step indicator at top (4 dots, filled = complete)

**Tests:** None (UI).

---

### Task 12: MenuBar + Home screen

**Goal:** Functional menubar icon with popover showing the home screen.

**Deliverables:**
- `MeetingMinutesApp.swift`:
  - `@main struct MeetingMinutesApp: App`
  - `@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate`
  - `body`: `Settings { EmptyView() }` (required for menubar-only app)
- `AppDelegate.swift`:
  - On `applicationDidFinishLaunching`: hide dock icon (`NSApp.setActivationPolicy(.accessory)`), create `NSStatusItem`, create `NSPopover` containing `RootView().environmentObject(appState)`
  - Status item button target: toggle popover
  - Icon: system image `"waveform"` for idle, `"waveform.badge.mic"` tinted red during recording
- `MenuBarView.swift` — root SwiftUI view inside popover:
  - Fixed size 400×560pt
  - Switches on `appState.phase`:
    - `.setup` → `SetupView()`
    - `.home` → `HomeView()`
    - `.recording` → `RecordingView()`
    - `.summary` → `SummaryView()`
- `HomeView.swift`:
  - Ollama status row: green dot "Ollama ready" or grey dot "No Ollama — transcript only"
  - Large "Start Recording" button (calls `appState.startRecording`)
  - "Recent Sessions" section: last 5 sessions, each row shows title + date + duration, tap → push `SummaryView` for that session
  - Settings gear button (top-right) → navigate to `SetupView`

**Tests:** None (UI).

---

### Task 13: Recording screen

**Goal:** Live scrolling transcript with speaker labels while recording is in progress.

**Deliverables:**
- `RecordingView.swift`:
  - Red recording indicator dot + "Recording" label
  - Timer showing elapsed time (HH:MM:SS), updates every second via `Timer.publish`
  - `ScrollViewReader` wrapping a `LazyVStack` of `MergedSegment` rows:
    - Each row: colored circle (Speaker 1 = blue, Speaker 2 = orange, Speaker 3 = green, Speaker 4 = purple, others = grey) + speaker label bold + text
    - Auto-scrolls to bottom on new segment
  - "Stop Recording" button (bottom, full-width, red) — calls `appState.stopRecording()`
  - While `appState.liveSegments.isEmpty`: centered "Listening…" with `ProgressView`

**Tests:** None (UI).

---

### Task 14: Summary screen

**Goal:** Display post-session summary, action items, full transcript, and export controls.

**Deliverables:**
- `SummaryView.swift`:
  - Session title (editable `TextField`, auto-saves on change)
  - Metadata row: date, duration, participant count
  - If `session.takeaways` not empty: "Key Takeaways" section with bulleted list
  - If `session.actionItems` not empty: "Action Items" section with `Toggle` per item (checking marks `isChecked`, auto-saves)
  - "Full Transcript" disclosure group (collapsed by default): scrollable list of `"{speakerLabel}: {text}"` rows
  - If `session.notionPageURL` is set: "Open in Notion" button (opens URL)
  - Else: "Export to Notion" button → calls `appState.exportToNotion()`, shows `ProgressView` while `appState.isExporting`, shows error if `appState.exportError` set
  - "Save as Markdown" button → writes to `~/Downloads/<session-title>.md`, shows success toast
  - "← Back" button (top-left) → `appState.phase = .home`
  - Markdown export format:
    ```
    # <title>
    Date: <date>  Duration: <duration>
    
    ## Key Takeaways
    - <takeaway>
    
    ## Action Items
    - [ ] <item>
    
    ## Transcript
    **<speakerLabel>**: <text>
    ```

**Tests:** None (UI).

---

### Task 15: Packaging + entitlements

**Goal:** Buildable, signable, distributable app with correct entitlements and a DMG.

**Deliverables:**
- `MeetingMinutes.entitlements` (complete, no placeholders):
  - `com.apple.security.app-sandbox = false` (required for SCStream + arbitrary file write to ~/Library)
  - `com.apple.security.network.client = true`
  - `com.apple.security.device.microphone = true`
  - `com.apple.security.cs.allow-unsigned-executable-memory = false`
- `Info.plist` (final):
  - `NSScreenCaptureUsageDescription`
  - `NSMicrophoneUsageDescription`
  - `LSUIElement = YES`
  - `CFBundleDisplayName = MeetingMinutes`
  - `CFBundleIconFile = AppIcon`
  - `NSHumanReadableCopyright`
- `scripts/build-dmg.sh`:
  ```bash
  xcodebuild archive -scheme MeetingMinutes -archivePath build/MeetingMinutes.xcarchive
  xcodebuild -exportArchive -archivePath build/MeetingMinutes.xcarchive \
    -exportPath build/export -exportOptionsPlist build/ExportOptions.plist
  create-dmg build/export/MeetingMinutes.app build/ --overwrite
  ```
- `build/ExportOptions.plist`: method = `"developer-id"` (or `"ad-hoc"` for unsigned distribution)
- `README.md` rewritten: what it does, requirements (macOS 14+, Apple Silicon, Ollama optional), install steps, first-launch setup guide
- App builds without warnings via `xcodebuild -scheme MeetingMinutes build`

**Tests:** Build succeeds.
