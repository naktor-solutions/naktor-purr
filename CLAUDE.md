# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Barktor is a local, on-device voice-to-text dictation app for macOS 14+ on Apple Silicon (a menu-bar `LSUIElement` app, no dock icon). Hold a hotkey, speak, and the transcript types into whatever text field is focused. Everything runs locally — no telemetry, no cloud. It's Naktor's fork of Purr (`iamarunbrahma/purr`), evolved independently. Single SwiftPM executable target, `Sources/Barktor/`.

## Build, run, test

The toolchain matters: some source is guarded by `#if canImport(FoundationModels)` (`@Generable` macros) that **only Xcode's compiler plugin can build**. On a machine with only Command Line Tools (no Xcode), you must compile those blocks out with `-DNO_APPLE_FM` and unset `DEVELOPER_DIR`. Nothing user-facing depends on FoundationModels — LLM post-processing and meeting summaries use Gemma via llama.cpp — so `NO_APPLE_FM` builds are fully functional.

- **Build + package the .app (Xcode present):** `make app` → `dist/Barktor.app`; `make run` builds and launches it.
- **Build on a CLT-only machine:** `env -u DEVELOPER_DIR swift build -c release --arch arm64 -Xswiftc -DNO_APPLE_FM`. `make app`'s default recipe assumes Xcode + a Developer ID cert and will fail here; use `scripts/release.sh` instead (it auto-detects CLT and takes the `NO_APPLE_FM` branch), or assemble/sign the bundle by hand mirroring the `make app` steps.
- **Tests:** `make test` (the recipe branches automatically for Xcode vs CLT — the CLT branch adds the framework search paths that Swift Testing needs). Tests use **Swift Testing** (`import Testing`), not XCTest. Run one suite/test with `swift test --filter <SuiteOrTestName>` (on CLT-only, prepend the same `-Xswiftc -DNO_APPLE_FM -Xswiftc -F ...` flags the Makefile's `test` target uses).
- **CLT caveat:** on a bare-CLT box, tests **compile and link but may not execute** — the Swift Testing runtime dylib (`lib_TestingInterop.dylib`) ships with Xcode, not CLT. Treat a clean compile as the local signal and verify logic by reasoning/build, not a green run.

## Signing and macOS permissions (read before shipping any build)

macOS ties TCC permissions (Microphone, Accessibility, Input Monitoring — all required, the app is non-sandboxed for `CGEventTap`/`CGEvent` paste) to the app's **code-signature designated requirement**, not its bundle id alone.

- **Sign every local build with the same stable cert — never ad-hoc.** An ad-hoc signature pins the requirement to the binary's cdhash, so *every rebuild* looks like a new app and forces the user to re-grant all three permissions. The project's cert is the self-signed **"Barktor Local Dev"** (`scripts/release.sh` uses it as `SIGN_ID`). Signed with it, the requirement is `identifier "com.naktor.barktor" and certificate leaf = H"..."` — identical across builds, so permissions persist.
- The cert must be present *and trusted* for code signing (`security find-identity -p codesigning -v` should list "Barktor Local Dev"; a self-signed cert needs `security add-trusted-cert -p codeSign` or it shows as invalid). See `docs/RELEASING.md`.
- Builds are **not Apple-notarized**, so a freshly downloaded DMG needs right-click → Open once; `spctl` will report "rejected" (expected).

## Architecture (the big picture)

`main.swift` → `AppDelegate` → **`AppCoordinator`** — a `@MainActor` class that is the central state machine and owns nearly everything: the active engine, `AudioRecorder`, `RecordingHUD`, `HotkeyManager`, the meeting pipeline, and `HistoryStore`. Most cross-cutting behavior lives here; start here when tracing a flow.

- **Engines** (`TranscriptionEngine` protocol): two implementations, both `@MainActor`.
  - `WhisperEngine` — WhisperKit/CoreML. Multilingual + optional translate-to-English. **Batch only** (streaming intentionally unsupported).
  - `ParakeetEngine` — FluidAudio (Parakeet TDT). English, fast; the default. Supports **both** batch and streaming (EOU = end-of-utterance chunked ASR for "smart typing" live preview).
  - Both expose `warmup()`, which loads and **ANE-compiles** the CoreML model — a one-time, multi-minute cost on a cold model. Warmups are **coalesced** onto a single in-flight task (`ParakeetEngine.batchLoadTask`, `WhisperEngine.warmupTask`) so a background warm-up and the first transcribe don't compile the same model twice concurrently.
- **Model files:** downloaded on demand into `~/Library/Application Support/Barktor/models` (Whisper checkpoints, Parakeet batch/EOU, the diarizer, and the Gemma GGUF), via `ModelManager` / `LLMModelManager`. The transcribe path deliberately does **not** auto-download — only the Settings UI pulls models (with progress); a missing model fails soft.
- **Dictation flow:** `HotkeyManager` (global `CGEventTap`) → `AudioRecorder` → `AudioPreprocessor.normalize` → `engine.transcribe` → `PostProcessor` (deterministic cleanup, "scratch that", etc.) → optional Gemma polish (`LLMPostProcessor`) → `TextInserter` (`CGEvent` paste). Smart-typing takes the streaming path through `ParakeetEngine`'s EOU session with a live HUD preview.
- **Meeting mode:** `MeetingPipeline` combines `SystemAudioCapture` + `EchoCanceller` (SpeexDSP, vendored in the `CEcho` C target) with the mic, transcribes with word timings (`DetailedTranscription`), aligns against `Diarizer` speaker segments into a `MeetingDocument`, and summarizes with `MeetingSummarizer` (Gemma).
- **LLM:** `LlamaRuntime`/`LlamaSession` wrap the `llama` binary XCFramework (Gemma 3 4B) for post-processing and summaries. Voice editing (`VoiceEditor`/`EditInterpreter`) also runs through it.
- **UI/state:** `RecordingHUD` is the floating pill (modes include `warmingUp`, `recording`, `transcribing`, `polishing`, `meeting`); `SettingsStore` (persisted prefs) + `SettingsView`; `HistoryStore`/`HistoryView` keep past dictations and their audio for retry; `Updater` checks GitHub releases (compares `CFBundleShortVersionString`, verifies the DMG's `.sha256` sidecar).

## Conventions

- **Version** lives in `Resources/Info.plist` (`CFBundleShortVersionString`). `CHANGELOG.md` follows Keep a Changelog; the in-app "What's New" ships the bundled `CHANGELOG.md`.
- **Branch model:** `main` = last released (currently 0.3.0). `develop` = next-version integration (currently `0.4.0-dev`). Cut feature branches off `develop` and merge back into it; release by merging `develop → main`, tagging `vX.Y.Z`, and running `scripts/release.sh`.
- The code is **densely commented with rationale** — most non-obvious decisions have a "why" next to them. Read the comments before changing behavior, and match that density.

## Where the deeper docs live

- `docs/RELEASING.md` — signing cert setup, the release/notarization flows, artwork swaps.
- `docs/BACKLOG.md` — planned work.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` — design specs and step-by-step implementation plans for larger features (meeting engine, history, LLM post-processing, Parakeet v3 spike).
