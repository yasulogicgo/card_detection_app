/// Hugging Face Space API (from gitignored `env.json` via --dart-define-from-file).
///
/// Setup: `scripts/setup.ps1` then edit `env.json`.
const String kHfSpaceBaseUrl = String.fromEnvironment(
  'HF_SPACE_BASE_URL',
  defaultValue: 'https://vidhilogicgo-card-detection.hf.space',
);

const String kDetectCardEndpoint = String.fromEnvironment(
  'HF_DETECT_CARD_ENDPOINT',
  defaultValue: 'https://vidhilogicgo-card-detection.hf.space/detect-card',
);

const String kHfApiToken = String.fromEnvironment(
  'HF_API_TOKEN',
  defaultValue: '',
);
