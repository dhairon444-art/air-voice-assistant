# PersonaPlex-MLX

MLX inference for NVIDIA PersonaPlex on Apple Silicon.

This package supports:

- Realtime local mode (`personaplex_mlx.local`)
- Realtime web mode (`personaplex_mlx.local_web`)
- Offline WAV-to-WAV mode (`personaplex_mlx.offline`)

Console entrypoints are also installed: `personaplex-local`, `personaplex-local-web`, `personaplex-offline`.

## Requirements

- Apple Silicon Mac
- Python 3.12
- Hugging Face access to `nvidia/personaplex-7b-v1`

Install:

```bash
pip install -e .
```

## Model Access

Accept the model license:
`https://huggingface.co/nvidia/personaplex-7b-v1`

Set your token:

```bash
export HF_TOKEN=<your_token>
```

## Quickstart

Launch realtime web mode (recommended first):

```bash
python -m personaplex_mlx.local_web \
  -q 4 \
  --voice NATF2 \
  --text-prompt "You enjoy having a good conversation."
```

Open `http://localhost:8998` in your browser.

Realtime local terminal mode:

```bash
python -m personaplex_mlx.local \
  -q 4 \
  --voice NATF2 \
  --text-prompt "You enjoy having a good conversation."
```

Offline inference:

```bash
python -m personaplex_mlx.offline \
  --voice NATF2 \
  --text-prompt "You are a wise and friendly teacher. Answer questions or provide advice in a clear and engaging way." \
  --input-wav input.wav \
  --output-wav output.wav \
  --output-text output.json \
  --seed 42424242
```

## Air: macOS app

`macos/Air` is a native macOS app for talking to local speech models. It has two modes; pick one in Settings. Only one mode's models are loaded at a time.

| Mode | How it works | Notes |
| --- | --- | --- |
| **Myra** | PersonaPlex 7B (this repo), full-duplex speech-to-speech | Very quick turn-taking and short replies. Your side is transcribed with Parakeet after the session. If the Mac slows down from heat, it skips pauses in your audio to catch up. |
| **Aria** | Pipeline: energy VAD, then Parakeet TDT 0.6B speech-to-text, then Qwen3-4B-Instruct-2507 (4-bit, streamed), then Kokoro-82M text-to-speech (`af_heart`) | Fuller, in-depth answers. About 1-2 s from the end of your speech to the first audio. Talk any time to interrupt. Both sides are transcribed live. |

- When the app opens it starts the selected mode's model process, bound to `127.0.0.1` on a free port, with `HF_HUB_OFFLINE=1`. Every file is read from the local Hugging Face cache.
- Quitting the app stops the models. If the app crashes or is force-quit, the model process notices that its parent has gone and exits on its own.
- Settings hold the mode, the voice and the persona. The persona presets (Warm companion, Thoughtful teacher, Coach) are written in the style of NVIDIA's PersonaPlex prompts, or you can write your own. Settings are stored per mode.
- Each conversation is saved as a Markdown note in the `Air` Obsidian vault (`~/Library/Mobile Documents/com~apple~CloudDocs/Obsidian vaults/Air`), at `Sessions/YYYY/MM/YYYY-MM-DD HHmm.md`. Each note has the mode and model ids in its frontmatter and timestamped `You:` / `Myra:` / `Aria:` lines. `Air Index.md` lists every session. The History tab reads these notes and can open any of them in Obsidian.
- Use headphones.

### Aria's tools

Aria can act on the Mac using the language model's tool calling. The app runs the tools in Swift (`macos/Air/Sources/Tools.swift`); the definitions and the confirmation wording are in `server/aria_tools.py`.

| Area | Runs directly | Needs your spoken "yes" first |
| --- | --- | --- |
| Apps | list running apps, open, switch to | quit |
| Calendar (EventKit) | read a day or a week | create, move, delete events |
| Reminders (EventKit) | read lists and open reminders | add, complete, delete |
| Air vault | search and read past conversations | create or append a note in `Air/Notes` |
| Files | find (Spotlight), open, reveal in Finder | (no file deletion at all) |
| System | date and time, battery, read volume | set volume, mute or unmute |
| Music | now playing, play, pause, next, previous | |
| Shortcuts | list | run a shortcut |
| Mail / Messages | unread mail count and senders (Mail must be open) | send email, send message |

- For anything that needs a "yes", Aria reads back exactly what she will do. Only a clear yes runs it; "no" or anything else cancels it.
- Every tool call (time, tool, arguments, confirmation, result) is logged in the session's Obsidian note.
- macOS asks for Calendar, Reminders or Automation access the first time a tool needs it. Aria says so and asks you to try again.
- Not available: brightness, Focus or Do Not Disturb (you can use a Shortcut for these), and unread iMessages, which macOS doesn't expose without Full Disk Access.
- If Aria says she did something without calling a tool, she is asked once to make the call. If she still doesn't, she says she hasn't done it.

Build and install (needs Xcode):

```bash
cd macos/Air
./build.sh             # builds macos/Air/build/Air.app
./build.sh --install   # also copies it to /Applications/Air.app (quit Air first)
```

Python environments:

- `AIR_MYRA_PYTHON` defaults to `~/personaplex-mlx/.venv/bin/python`. This venv needs this package's dependencies; the app bundles its own copy of `personaplex_mlx`.
- `AIR_ARIA_PYTHON` defaults to `~/Library/Application Support/Air/venv-smart/bin/python`. This venv has `mlx-audio`, `mlx-lm`, `misaki`, `spacy` with `en_core_web_sm`, `num2words`, `phonemizer-fork`, `espeakng-loader`, `scipy` and `aiohttp`. Install `misaki` without its `[en]` extra to avoid pulling in torch.

Aria's models are `mlx-community/Qwen3-4B-Instruct-2507-4bit`, `mlx-community/parakeet-tdt-0.6b-v2` and `mlx-community/Kokoro-82M-bf16`. Download them once with `huggingface_hub.snapshot_download`. The server log is written to `~/Library/Logs/Air/server.log`.

On first launch, allow microphone access when macOS asks. To use "Open in Obsidian", add the vault to Obsidian once: Open another vault → Open folder as vault → `Obsidian vaults/Air`.

## Voices

Built-in voice IDs:

- `NATF0` `NATF1` `NATF2` `NATF3`
- `NATM0` `NATM1` `NATM2` `NATM3`
- `VARF0` `VARF1` `VARF2` `VARF3` `VARF4`
- `VARM0` `VARM1` `VARM2` `VARM3` `VARM4`

`--voice NATF2` resolves to `NATF2.pt` from the downloaded `voices/` bundle.

## Notes

- First run downloads model assets from Hugging Face.
- Local and web clients are barebone and do not include echo cancellation. Use headphones to avoid feedback.

## Attribution

This project is an MLX port of NVIDIA PersonaPlex for Apple Silicon.

- NVIDIA PersonaPlex repo: `https://github.com/NVIDIA/personaplex`
- PersonaPlex model card: `https://huggingface.co/nvidia/personaplex-7b-v1`

## Citation

If you use PersonaPlex in research, cite:

```bibtex
@misc{roy2026personaplexvoicerolecontrol,
  title={PersonaPlex: Voice and Role Control for Full Duplex Conversational Speech Models},
  author={Rajarshi Roy and Jonathan Raiman and Sang-gil Lee and Teodor-Dumitru Ene and Robert Kirby and Sungwon Kim and Jaehyeon Kim and Bryan Catanzaro},
  year={2026},
  eprint={2602.06053},
  archivePrefix={arXiv},
  primaryClass={cs.CL},
  url={https://arxiv.org/abs/2602.06053}
}
```

## License

- Code: MIT (`LICENSE`)
- Model weights: NVIDIA Open Model License (via Hugging Face model card)
