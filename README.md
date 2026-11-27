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

`macos/Air` is a native macOS voice assistant, Aria, that runs entirely on the Mac. The pipeline: energy-based turn detection, Parakeet TDT 0.6B speech-to-text, a local Qwen3 language model (4-bit, streamed), then Kokoro-82M text-to-speech. About 1-2 s passes from the end of your speech to the first audio. You can talk at any time to interrupt, and both sides are transcribed.

- When the app opens it starts Aria's model process, bound to `127.0.0.1` on a free port, with `HF_HUB_OFFLINE=1`. Model files are read from the local Hugging Face cache.
- Quitting the app stops the models. If the app crashes or is force-quit, the model process notices that its parent has gone and exits on its own.
- **Talk screen:** pick the personality and one of five voices (Heart, Bella, Nicole, Emma, Sarah; each has a preview button).
- **Settings:** the Brain map (below), and an editor for each personality.
- **Talker and Thinker:** the talker (default Gemma 4 E4B) is the voice you hear: conversation and simple actions. A thinker (default Qwen3.5 9B) sits behind it for reasoning, writing, research and multi-step requests, and for any specialist lens or panel the Orchestrator brings in. Routing is rule-based and takes no measurable time; the talker says a short line ("Let me dig into that") while the thinker works. The thinker primes its prompt in the background in small steps, so the talker's turns never wait for it.
- **Brain map** (Settings): presets (Light, Balanced, Best), a flow map whose path lights up for the last request, drag and drop of installed models onto the talker, thinker and heavy-brain roles, and a memory meter that warns before a combination that's too big for 24 GB.
- **Cloud heavy brain (optional):** keys for Claude (Anthropic) and Gemini (Google) are stored in the macOS Keychain. With one set as the heavy brain, Aria asks before each use ("Should I use Claude for this?"), badges replies that used it, logs a cost estimate and falls back to local when offline. Only the question and the conversation are sent; the profile and recalled notes only if you allow it, and never screenshots.
- **Personalities:** Analyst (default), Sparring Partner and Mentor, plus Custom. Each is a layered spec: identity, ranked values (truth, then usefulness, then comfort), rules for facts and confidence, anti-flattery rules, spoken style, memory and tool use, and example exchanges. They ship in `Resources/personas.json`.
- **Memory:** after each conversation Aria writes a summary into the session note and adds new facts to `Profile.md` in the vault (goals, preferences, decisions, corrections, open threads). She never deletes lines there, so your edits stay. At the start of a conversation, the profile and the three most recent summaries are loaded. Older summaries are recalled turn by turn with BM25.
- **Notes:** each conversation is saved in the `Air` Obsidian vault (`~/Library/Mobile Documents/com~apple~CloudDocs/Obsidian vaults/Air`) at `Sessions/YYYY/MM/YYYY-MM-DD HHmm.md`, with timestamped `You:` and `Aria:` lines. `Air Index.md` lists every session.
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
| Web (only the query or link leaves the Mac) | search and fact-check (DuckDuckGo, Wikipedia), open a link or a numbered source, read a page, extract tables, links, prices and dates, get a video transcript from its captions | transcribe a video without captions here (temporary audio, deleted afterwards) |
| Exports | save the last transcript or extraction as Excel, Word, CSV or a vault note in `~/Documents/Air Exports` (never overwrites) | |

- For anything that needs a "yes", Aria reads back exactly what she will do. Only a clear yes runs it; "no" or anything else cancels it.
- Every tool call (time, tool, arguments, confirmation, result) is logged in the session's Obsidian note.
- macOS asks for Calendar, Reminders or Automation access the first time a tool needs it. Aria says so and asks you to try again.
- Not available: brightness, Focus or Do Not Disturb (you can use a Shortcut for these), and unread iMessages, which macOS doesn't expose without Full Disk Access.
- Before each sentence is spoken, it is checked for a claim of an action that no tool performed. If it contains one, Aria stops, is asked once to make the call, and otherwise says she hasn't done it.
- Online fact-check is on by default (Settings). Connectivity is checked in the background. Offline, or when the 1.5 s search budget runs out, Aria answers from the model and says she couldn't verify. Sources and every URL opened or read are listed in the session note.
- Think first (Settings; brains that can reason, not Fast) reasons silently before answering, with a 256-token budget.

Build and install (needs Xcode):

```bash
cd macos/Air
./build.sh             # builds macos/Air/build/Air.app
./build.sh --install   # also copies it to /Applications/Air.app (quit Air first)
```

Python environments:

- `AIR_ARIA_PYTHON` defaults to `~/Library/Application Support/Air/venv-smart/bin/python`. This venv has `mlx-audio`, `mlx-lm`, `misaki`, `spacy` with `en_core_web_sm`, `num2words`, `phonemizer-fork`, `espeakng-loader`, `scipy`, `aiohttp`, `trafilatura`, `youtube-transcript-api`, `yt-dlp`, `openpyxl` and `python-docx`. ffmpeg (Homebrew) is only needed to transcribe videos that have no captions. Install `misaki` without its `[en]` extra to avoid pulling in torch.

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
