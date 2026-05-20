# card_detacstion_app

A new Flutter project.

## Hugging Face API token (card detection)

The app calls the Space at `detect-card` and may send `Authorization: Bearer …`
only when a token is provided. **Do not put tokens in source control.**

Run locally:

```bash
flutter run --dart-define=HF_API_TOKEN=your_hf_token
```

If a token was ever committed, **revoke it** in your Hugging Face account and create a new one.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
