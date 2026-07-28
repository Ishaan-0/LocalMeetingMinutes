# MeetingMinutes SDD Progress Ledger (Swift Rewrite)

Plan: docs/plan.md

## Tasks

- [x] Task 1: Xcode project + Swift package setup — commit fb91016, review clean
- [x] Task 2: Audio capture manager — commits fb91016..7876b7b, review clean
- [ ] Task 3: WhisperKit transcription — NEEDS RE-REVIEW (fixes committed f2a6a63, multi-window drain + removed @MainActor + flush() throws)
- [ ] Task 4: Speaker diarization
- [ ] Task 5: Segment merger
- [ ] Task 6: Keychain + session store
- [ ] Task 7: Ollama service
- [ ] Task 8: Notion service
- [ ] Task 9: Model download manager
- [ ] Task 10: AppState + session coordinator
- [ ] Task 11: Setup screen
- [ ] Task 12: MenuBar + Home screen
- [ ] Task 13: Recording screen
- [ ] Task 14: Summary screen
- [ ] Task 15: Packaging + entitlements

## Minor findings log
- Task 1: `SWIFT_VERSION = 5.0` in pbxproj — should be bumped to `5.9` before any 5.9-specific syntax is used
- Task 1: WhisperKit version floor spec-ambiguous (`upToNextMajorVersion(0.9.0)` vs spec's `1.0.0`) — identical resolved version (0.18.0), no action needed unless 1.0 ships
- Task 1: `ARCHS` not locked to `arm64` in pbxproj (spec says Apple Silicon primary target)
- Task 2: Buffer starvation if one audio source stalls (no zero-pad flush) — acceptable v1 debt
- Task 2: `stagingLock` unlock/relock in drain loop — latent out-of-order emit under high concurrency
- Task 2: `AudioRingBuffer` implemented but unused by `AudioCaptureManager` (staging arrays used instead)
