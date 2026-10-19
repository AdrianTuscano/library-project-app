// TEMPLATE — committed to the repo as documentation.
//
// On a fresh clone: cp lib/ocr_secrets.example.dart lib/ocr_secrets.dart
// then fill these in. Leave blank to fall back to on-device OCR.
//
// kClaudeProxyUrl/kClaudeProxyAppSecret come from deploying
// cloud/claude-proxy — see its DEPLOY.md. Nothing here is a raw
// Anthropic key; that lives server-side only.
//
// OCR priority: Claude (via proxy) → Cloud Vision → on-device ML Kit.
const String kVisionApiKey = '';
const String kClaudeProxyUrl = '';
const String kClaudeProxyAppSecret = '';
