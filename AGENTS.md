# AGENTS.md

This file is for coding agents working in this repository.

## Project Snapshot

- App: local macOS menu bar app (`SwiftUI` + `AppKit`) for meeting transcription.
- Recording: captures **system audio + microphone** and mixes into one WAV before ASR.
- ML pipeline: Python worker with MLX ASR + pyannote diarization.
- Output: Markdown transcript (+ optional JSON metadata), local-only.

## Current Architecture

### Swift app (`MacMenuBarApp/Sources/Oppy`)

- `OppyApp.swift`: menu bar app entry and settings scene.
- `PopoverView.swift`: primary UX (`Start`, `Stop`, open folder, settings, preflight status).
- `AppStateStore.swift`: session state machine and orchestration.
- `AudioRecorder.swift`: recording backend.
  - Uses `ScreenCaptureKit` for system audio.
  - Uses `SCStream` microphone on macOS 15+.
  - Uses `AVAudioEngine` fallback microphone capture on macOS 14.
- `WorkerLauncher.swift`: starts Python worker process and parses line-delimited JSON events.
- `SettingsStore.swift`: persistent defaults (`UserDefaults`).
- `KeychainService.swift`: Hugging Face token storage in macOS Keychain.

### Python worker (`worker`)

- `main.py`: worker entrypoint, progress/result protocol, orchestration.
- `pipeline/input_mix.py`: merges `<session>.wav` + `<session>.mic.wav` into main WAV.
- `pipeline/asr.py`: MLX transcription with compatibility shims.
- `pipeline/diarization.py`: pyannote diarization handling modern `DiarizeOutput` API.
- `pipeline/merge.py`: aligns speaker turns to ASR segments.
- `pipeline/export.py`: writes markdown/json atomically.

## Critical Behavior and Known Gotchas

1. **ASR model ID compatibility matters**
   - Default should remain: `mlx-community/whisper-large-v3-turbo-asr-fp16`.
   - Generic IDs like `mlx-community/whisper-large-v3-turbo` can fail processor/tokenizer paths.

2. **System audio capture requires Screen Recording permission**
   - Microphone permission alone is insufficient.
   - Preflight status in the popover should stay accurate.

3. **Diarization model is gated on HF**
   - `pyannote/speaker-diarization-3.1` requires account access acceptance.
   - Missing access/token should be user-actionable.

4. **Diarization failure fallback is intentional**
   - Worker should still export transcript with `Speaker ?` labels if diarization fails.
   - Do not regress this unless explicitly changing product behavior.

5. **Keep WAV behavior is intentional**
   - Session WAV is retained after processing.

## Runbook

### Setup

```bash
cd /Users/luisperichon/oppy
python3 -m venv worker/.venv
worker/.venv/bin/python -m pip install -r worker/requirements.txt
```

### Run app

```bash
cd /Users/luisperichon/oppy
swift run Oppy
```

### Regression checks

```bash
cd /Users/luisperichon/oppy
./scripts/test.sh
```

## Testing Expectations

- Python tests are the primary regression suite.
- Current coverage includes:
  - merge logic
  - export formatting and file writing
  - worker config defaults
  - worker orchestration happy path
  - missing token guardrail
  - diarization failure fallback
  - audio mixing behavior
- Keep `./scripts/test.sh` green before finalizing changes.

## Protocol Contract (Swift <-> Worker)

- Worker emits JSON lines to stdout.
- Progress events:
  - `{"type":"progress","stage":"...","message":"..."}`
- Final result:
  - `{"type":"result","success":true|false,...}`
- Swift parser in `WorkerLauncher.swift` depends on this shape.

## Guardrails for Future Changes

- Preserve minimal menu bar UX unless user asks for a redesign.
- Preserve local-only behavior (no cloud transcription).
- Do not store HF token outside Keychain.
- If touching recording pipeline, verify both:
  - macOS 15+ microphone capture path
  - macOS 14 fallback microphone path
- If touching ASR model handling, validate with real model IDs used in Settings defaults.

## Fast Validation Checklist

After non-trivial edits:

1. `swift build`
2. `./scripts/test.sh`
3. Manual smoke (if recording/UX changed):
   - start/stop recording
   - confirm preflight line
   - confirm transcript is saved
   - confirm WAV retained
