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

