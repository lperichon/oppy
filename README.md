# Oppy

Oppy is a local macOS menu bar app that records meetings, runs offline transcription with MLX ASR models, applies pyannote diarization, and writes speaker-labeled Markdown transcripts.

## Implemented v1

- Native menu bar UX with start/stop controls, timer, status, and settings.
- Hugging Face token storage in macOS Keychain.
- Per-session `.wav` capture and retention.
- Post-stop Python worker pipeline:
  - ASR via `mlx-audio`
  - diarization via configurable pyannote model
  - timestamp and speaker merge
  - Markdown export (+ optional JSON)

## Project Layout

- `Package.swift`: Swift package entry.
- `MacMenuBarApp/Sources/Oppy`: app source.
- `worker`: Python pipeline and dependencies.

## Prerequisites

1. Apple Silicon Mac.
2. Full Xcode installed and selected (`xcode-select -s /Applications/Xcode.app`).
3. Python 3.11+ available as `python3`.
4. Hugging Face account + token.
5. Accept conditions for your diarization model (default `pyannote/speaker-diarization-3.1`).

## Setup

```bash
cd /Users/luisperichon/oppy
python3 -m venv worker/.venv
source worker/.venv/bin/activate
pip install -r worker/requirements.txt
```

## Run

```bash
cd /Users/luisperichon/oppy
swift run Oppy
```

Then open `Settings` from the menu bar popover and configure:

- Transcript folder
- ASR model
- Diarization model
- Language mode (`auto` or fixed code)
- Save JSON metadata toggle
- Hugging Face token (saved in Keychain)

## Notes

- Add a microphone usage description in app signing/distribution contexts.
- First run may download large ASR/diarization models.
- Worker protocol is line-delimited JSON over stdout.
