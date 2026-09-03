# ai_live_translator_mobile

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Live STT session binding

`STT_SESSION_ID` is an optional technical bridge for binding Mobile STT to a
backend viewer session. When omitted or blank, Mobile starts STT without a
session ID.

```powershell
flutter run `
  -d "192.168.1.170:44663" `
  --dart-define=STT_SESSION_ID=demo-001
```
