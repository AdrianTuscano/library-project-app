import 'package:flutter/foundation.dart';
import 'ocr_secrets.dart' as secrets;

const String _envVisionKey = String.fromEnvironment('VISION_KEY');

// Blank in Release and Profile both — a Profile IPA is distributable too,
// not just Release (kReleaseMode alone missed that).
const bool _blankKeys = kReleaseMode || kProfileMode;

const String kCloudVisionApiKey =
    _blankKeys ? '' : (_envVisionKey != '' ? _envVisionKey : secrets.kVisionApiKey);

// Claude OCR goes through the Cloud Function in cloud/claude-proxy, which
// holds the real Anthropic key server-side — the app itself never embeds
// it, so these are fine to ship in every build mode. The app secret is
// just a deterrent against drive-by hits on the proxy URL, not real auth;
// see DEPLOY.md for the actual cost backstop.
const String kClaudeProxyUrl = secrets.kClaudeProxyUrl;
const String kClaudeProxyAppSecret = secrets.kClaudeProxyAppSecret;
