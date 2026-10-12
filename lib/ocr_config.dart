import 'package:flutter/foundation.dart';
import 'ocr_secrets.dart' as secrets;

const String _envVisionKey = String.fromEnvironment('VISION_KEY');
const String _envAnthropicKey = String.fromEnvironment('ANTHROPIC_KEY');

const String kCloudVisionApiKey = kReleaseMode
    ? ''
    : (_envVisionKey != '' ? _envVisionKey : secrets.kVisionApiKey);

// Never ship provider keys: anything in an App Store binary can be extracted.
// Release builds compile them out (const-folded) and read spines on-device
// until a backend proxy holds the key.
// TODO(release): route Claude calls through that proxy.
const String kAnthropicApiKey = kReleaseMode
    ? ''
    : (_envAnthropicKey != '' ? _envAnthropicKey : secrets.kAnthropicApiKey);
