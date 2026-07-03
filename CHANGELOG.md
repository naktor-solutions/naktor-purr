# Changelog

All notable changes to Barktor are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org).

## [0.3.0] - 2026-07-03

### Changed
- **Purr is now Barktor.** New app name, bundle identifier
  (`com.naktor.barktor`), repository (`naktor-solutions/barktor`), and
  release asset names (`Barktor.dmg`). Because the bundle identifier
  changed, macOS asks you to re-grant the three permissions once after
  updating.
- Default meetings folder is now
  `~/Library/Application Support/Barktor/Meetings`.
- The DMG install window was redrawn for Barktor and is now sharp on
  Retina displays.

### Fixed
- The menu bar icon could fail to appear at all on macOS Tahoe (the app had
  no main menu, which can orphan the status item). Ported from upstream Purr.
- A hung transcription (CoreML never returning) no longer pins the HUD on
  "Transcribing" forever; it now stops with a clear error after a generous,
  audio-proportional timeout. Ported from upstream Purr.

### Added
- New Barktor app icon and menu-bar glyph.
- One-time migration from a 0.2.x Purr install: settings, dictation
  history, downloaded models, and meeting transcripts all move to the new
  identity automatically on first launch. If you update in place from
  0.2.0, the bundle in /Applications keeps its old `Purr.app` file name -
  installing fresh from the DMG (and deleting `Purr.app`) is recommended.

## [0.2.0] - 2026-07-03

First Naktor release, forked from
[iamarunbrahma/purr](https://github.com/iamarunbrahma/purr) at 0.0.1.

### Added
- **Meeting engine picker**: meetings can now transcribe with Whisper (any
  language, word-level timings for speaker attribution) or Parakeet, instead
  of always forcing Parakeet (English-only).
- **Dictation history** (Settings > History, and a History window in the menu):
  every dictation is kept with its text, audio, engine, duration and status.
  Audio is saved *before* transcription, so failed, interrupted or cancelled
  dictations can be **retried** with any engine. Includes copy, raw-vs-processed
  toggle, WAV export, per-entry and delete-all, configurable audio retention,
  and a stats header (words, average WPM, day streak).
- **AI cleanup** (Settings > Features): optional local LLM post-processing of
  batch dictations with Gemma 3 4B - "Clean up" (punctuation, false starts,
  spoken lists; never changes your words) or "Rewrite" (clarity, same meaning
  and language), plus free-form custom instructions. Every failure path falls
  back to the standard deterministic cleanup; a dictation is never lost.
- **Esc cancels** an in-flight dictation. The audio still lands in History as
  a cancelled entry, so a mistaken Esc loses nothing.
- **Hands-free lock**: in hold-to-talk, a quick double-press locks the
  recording on with no key held; the next press stops it.
- **Open at login** and **sound cues** toggles (Settings > General).
- **Reopening Purr.app** (Finder, Spotlight, Launchpad) now surfaces Settings -
  or Onboarding while setup is incomplete - so a crowded menu bar or the notch
  can no longer strand you with no way into the app.
- **What's New in About**: the About window shows the installed version and
  this changelog.

### Changed
- History rows redesigned: cards with hover-revealed actions, a prominent
  Copy button with the rest behind an ellipsis menu, and readable model names
  ("Whisper · Large V3 Turbo" instead of the model filename).
- App identity: bundle identifier is now `com.naktor.purr` and the in-app
  updater follows releases of `naktor-solutions/naktor-purr`. Updating from
  an upstream 0.0.x install requires re-granting permissions once.

### Security
- LLM prompts hardened against prompt injection: dictated text is delimited
  and treated strictly as data (the model no longer answers or auto-completes
  what you dictate), and Gemma chat-template control tokens are neutralized in
  all interpolated content (dictations, voice-edit selections, meeting
  transcripts, custom instructions).
