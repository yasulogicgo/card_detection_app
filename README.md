# card_detacstion_app

Flutter card detection app with camera, OpenCV crop, and Hugging Face API.

## One-time setup (API token — do this once)

GitHub **blocks pushes** if a Hugging Face token (`hf_...`) is in any commit.  
Keep the token only in a **local file** that git never tracks.

### Windows (PowerShell)

```powershell
cd C:\Users\yasu.v.lakhani\StudioProjects\card_detacstion_app
.\scripts\setup.ps1
```

Then open **`env.json`** (created from `env.json.example`) and replace `paste_your_hf_token_here` with your real token.

### Run the app

- **VS Code / Cursor**: use launch config **"card_detacstion_app (with API token)"** (uses `env.json` automatically)
- **Terminal**:

```powershell
.\scripts\run.ps1
```

or:

```bash
flutter run --dart-define-from-file=env.json
```

### Git push

After setup, a **pre-commit hook** stops you from committing `hf_` tokens by mistake.  
You can push normally — `env.json` is in `.gitignore` and will not be uploaded.

If a token was ever committed before, **revoke it** on [Hugging Face → Access Tokens](https://huggingface.co/settings/tokens) and use a new one in `env.json` only.

## Getting Started

- [Flutter documentation](https://docs.flutter.dev/)
