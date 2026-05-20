/// Hugging Face Space API settings.
///
/// **Do not commit real tokens.** Set at build/run time:
/// `flutter run --dart-define=HF_API_TOKEN=your_token_here`
///
/// For release builds, configure the same define in your CI or IDE run config.
const String kDetectCardEndpoint =
    'https://vidhilogicgo-card-detection.hf.space/detect-card';

const String kHfApiToken = String.fromEnvironment(
  'HF_API_TOKEN',
  defaultValue: '',
);
