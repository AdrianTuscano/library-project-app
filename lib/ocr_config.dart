import 'ocr_secrets.dart' as secrets;

const String _envVisionKey = String.fromEnvironment('VISION_KEY');
const String _envAnthropicKey = String.fromEnvironment('ANTHROPIC_KEY');

final String kCloudVisionApiKey =
    _envVisionKey.isNotEmpty ? _envVisionKey : secrets.kVisionApiKey;

final String kAnthropicApiKey =
    _envAnthropicKey.isNotEmpty ? _envAnthropicKey : secrets.kAnthropicApiKey;
