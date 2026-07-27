import 'ocr_secrets.dart' as secrets;

// OCR backend configuration.
//
// Cloud Vision gives markedly better results on rotated / dense spine text than
// on-device ML Kit. It activates automatically when an API key is available; if
// the key is blank or a cloud call fails, the app falls back to on-device OCR.
//
// The key lives in lib/ocr_secrets.dart, which is git-ignored so it never gets
// committed (this repo is public). A --dart-define=VISION_KEY=... overrides it
// if you'd rather pass it at build time.
//
// SECURITY: a key shipped in a mobile binary can be extracted. In the Google
// Cloud console, restrict this key to the Cloud Vision API only (and ideally to
// your app's bundle id). For real distribution, proxy calls through a backend.
const String _envKey = String.fromEnvironment('VISION_KEY');

final String kCloudVisionApiKey =
    _envKey.isNotEmpty ? _envKey : secrets.kVisionApiKey;
