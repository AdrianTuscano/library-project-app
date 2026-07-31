import 'ocr_secrets.dart' as secrets;

// OCR backend priority: Claude Vision → Cloud Vision → on-device ML Kit.
// Keys live in lib/ocr_secrets.dart (git-ignored). Dart-define env vars
// override at build time. Claude is tried first when its key is present —
// it reads AND identifies books in one step, giving much better accuracy.

const String _envVisionKey = String.fromEnvironment('VISION_KEY');
const String _envAnthropicKey = String.fromEnvironment('ANTHROPIC_KEY');

final String kCloudVisionApiKey =
    _envVisionKey.isNotEmpty ? _envVisionKey : secrets.kVisionApiKey;

// ignore: prefer_const_declarations
final String kAnthropicApiKey =
    _envAnthropicKey.isNotEmpty ? _envAnthropicKey : secrets.kAnthropicApiKey;
