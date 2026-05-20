/// Hugging Face Space API settings.
///
/// Token is **not** stored in this repo. One-time setup:
/// 1. Run `scripts/setup.ps1` (creates gitignored `env.json`)
/// 2. Paste your token into `env.json`
/// 3. Run with `--dart-define-from-file=env.json` (VS Code launch config does this)
const String kDetectCardEndpoint =
    'https://vidhilogicgo-card-detection.hf.space/detect-card';

const String kHfApiToken = String.fromEnvironment(
  'HF_API_TOKEN',
  defaultValue: '',
);
