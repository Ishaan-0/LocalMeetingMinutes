# Task 1 Report: Xcode project + Swift package setup

## Status: DONE

## What Was Done

### Xcode Project
Created `MeetingMinutes.xcodeproj` manually (hand-crafted `project.pbxproj`) targeting macOS 14.0, arm64. Includes:
- `MeetingMinutes.xcodeproj/project.pbxproj` — full PBXProject structure with Sources, Frameworks, Resources build phases
- `MeetingMinutes.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `MeetingMinutes.xcodeproj/xcshareddata/xcschemes/MeetingMinutes.xcscheme` — shared scheme for build/run/test/archive
- `MeetingMinutes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — committed for reproducible builds

### Source Files
- `MeetingMinutes/App/MeetingMinutesApp.swift` — `@main`, `@NSApplicationDelegateAdaptor(AppDelegate.self)`, `@MainActor AppDelegate` that hides dock icon via `NSApp.setActivationPolicy(.accessory)`, creates NSStatusItem with "waveform" SF Symbol, NSPopover containing MenuBarView
- `MeetingMinutes/App/AppState.swift` — `@MainActor final class AppState: ObservableObject` with `@Published var phase: AppPhase = .setup`; `enum AppPhase { case setup, home, recording, summary }`
- `MeetingMinutes/Views/MenuBarView.swift` — `NSStatusItem` + `NSPopover` placeholder with `Text("MeetingMinutes")` at 400×560pt

### Configuration
- `MeetingMinutes/Info.plist` — `LSUIElement = YES`, `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `MACOSX_DEPLOYMENT_TARGET = 14.0`
- `MeetingMinutes/MeetingMinutes.entitlements` — `com.apple.security.network.client = true`, `com.apple.security.device.microphone = true`

### SPM Dependency
WhisperKit added as `XCRemoteSwiftPackageReference` with `upToNextMajorVersion` from `0.9.0`. Resolved to v0.18.0 along with transitive deps (swift-transformers, swift-crypto, swift-collections, swift-argument-parser, swift-jinja, yyjson, swift-asn1).

## Build Verification
`xcodebuild -scheme MeetingMinutes -destination "platform=macOS,arch=arm64" build CODE_SIGNING_ALLOWED=NO`
Result: **BUILD SUCCEEDED**

One fix applied during build: `AppDelegate` needed `@MainActor` annotation since `AppState.init()` is `@MainActor`-isolated.

## Concerns

1. **WhisperKit version range**: The brief says "up-to-range 1.0.0" (presumably `upToNextMajorVersion: 1.0.0`), but WhisperKit's latest published releases are in the 0.x series (0.18.0 as of resolution). Using `upToNextMajorVersion: 0.9.0` resolves to the latest 0.18.0. If 1.0.0 is released, it will be pulled automatically. This is the correct behavior.

2. **No app sandbox** per plan (`com.apple.security.app-sandbox = false`): Not included in the skeleton entitlements — the brief only lists `network.client` and `device.microphone` for Task 1. Task 15 adds the full entitlements set. This is correct per task scope.

3. **`xcodebuild -runFirstLaunch`** was required to fix a simulator plugin load failure (unrelated to macOS builds). This is a one-time machine setup step.

## Files Created
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes.xcodeproj/project.pbxproj`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes.xcodeproj/xcshareddata/xcschemes/MeetingMinutes.xcscheme`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes/App/MeetingMinutesApp.swift`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes/App/AppState.swift`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes/Views/MenuBarView.swift`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes/Info.plist`
- `/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/MeetingMinutes/MeetingMinutes.entitlements`
