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

## Myra: macOS app

`macos/Myra` wraps the model in a native macOS app. Open Myra.app and talk to the model in its own window. There is no browser and no server left running.

- When the app opens it starts the model as a child process bound to `127.0.0.1` on a free port, with `HF_HUB_OFFLINE=1`. Every file is read from the local Hugging Face cache.
- Quitting the app stops the model. If the app crashes or is force-quit, the model process notices that its parent has gone and exits on its own.
- Settings (voice and persona) are remembered between launches. Changes apply to the next conversation.
- Each conversation is saved as a Markdown note in the `Myra` Obsidian vault (`~/Library/Mobile Documents/com~apple~CloudDocs/Obsidian vaults/Myra`), at `Sessions/YYYY/MM/YYYY-MM-DD HHmm.md`. `Myra Index.md` lists every session, newest first. The History tab reads these notes and can open any of them in Obsidian.
- Only Myra's side is transcribed. PersonaPlex streams the text of what it says, not what you say.
- Use headphones, because there is no echo cancellation.

Build and install (needs Xcode and an existing venv that has this package's dependencies installed):

```bash
cd macos/Myra
./build.sh             # builds macos/Myra/build/Myra.app
./build.sh --install   # also copies it to /Applications/Myra.app (quit Myra first)
```

By default the app runs `~/personaplex-mlx/.venv/bin/python`. To use a different venv, set `MYRA_PYTHON=/path/to/bin/python` when you build. The app bundles its own copy of `personaplex_mlx`, so the venv only needs the dependencies. The server log is written to `~/Library/Logs/Myra/server.log`.

On first launch, allow microphone access when macOS asks. To use "Open in Obsidian", add the vault to Obsidian once: Open another vault → Open folder as vault → `Obsidian vaults/Myra`.

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
