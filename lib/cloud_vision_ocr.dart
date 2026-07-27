import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'book_scanner.dart';
import 'ocr_service.dart'; // OcrResult, OcrException

// ─────────────────────────────────────────────────────────────────────────────
// CloudVisionOcr — Google Cloud Vision text detection
//
// DOCUMENT_TEXT_DETECTION handles rotated and dense spine text far better than
// on-device ML Kit, and returns per-word bounding boxes we can cluster by X
// directly — so no multi-orientation trickery is needed here.
//
// The image is downscaled before upload to keep the request small and fast.
// ─────────────────────────────────────────────────────────────────────────────

class CloudVisionOcr {
  final String apiKey;
  CloudVisionOcr({required this.apiKey});

  static const int maxDimension = 2200; // longest side, px, before upload

  Future<OcrResult> recognize(String imagePath) async {
    final b64 = await compute(_encodeForUpload, imagePath);
    if (b64.isEmpty) {
      throw const OcrException('Could not read image for upload');
    }

    final uri = Uri.https(
      'vision.googleapis.com',
      '/v1/images:annotate',
      {'key': apiKey},
    );
    final payload = jsonEncode({
      'requests': [
        {
          'image': {'content': b64},
          'features': [
            {'type': 'DOCUMENT_TEXT_DETECTION'}
          ],
          'imageContext': {
            'languageHints': ['en']
          },
        }
      ]
    });

    http.Response res;
    try {
      res = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'}, body: payload)
          .timeout(const Duration(seconds: 12));
    } on SocketException catch (e) {
      throw OcrException('Network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw OcrException('Network error: ${e.message}');
    }

    if (res.statusCode != 200) {
      throw OcrException('Vision API ${res.statusCode}: ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final responses = data['responses'] as List?;
    if (responses == null || responses.isEmpty) {
      return const OcrResult(words: [], rotationUsed: 'cloud', rawText: '');
    }

    final first = responses.first as Map<String, dynamic>;
    if (first['error'] != null) {
      throw OcrException('Vision API error: ${first['error']}');
    }

    final annotations = first['textAnnotations'] as List?;
    if (annotations == null || annotations.isEmpty) {
      return const OcrResult(words: [], rotationUsed: 'cloud', rawText: '');
    }

    // Index 0 is the aggregate full-text block; individual words follow.
    final fullText =
        (annotations.first as Map)['description'] as String? ?? '';

    final words = <ScanWord>[];
    for (var i = 1; i < annotations.length; i++) {
      final a = annotations[i] as Map<String, dynamic>;
      final text = a['description'] as String? ?? '';
      final verts = (a['boundingPoly']?['vertices'] as List?) ?? const [];
      if (text.isEmpty || verts.isEmpty) continue;

      var sumX = 0.0;
      var n = 0;
      for (final v in verts) {
        final x = (v as Map)['x'];
        if (x is num) {
          sumX += x.toDouble();
          n++;
        }
      }
      if (n == 0) continue;
      // Vision returns words in reading order; keep that as the order index.
      words.add(ScanWord(text: text, centerX: sumX / n, order: words.length));
    }

    debugPrint('[CloudVision] ${words.length} words detected');
    return OcrResult(words: words, rotationUsed: 'cloud', rawText: fullText);
  }
}

// ─── Runs in a background isolate (top-level for `compute`) ──────────────────
// Downscales the captured frame and returns base64 JPEG for upload.
String _encodeForUpload(String path) {
  try {
    final decoded = img.decodeImage(File(path).readAsBytesSync());
    if (decoded == null) return '';

    final longest =
        decoded.width > decoded.height ? decoded.width : decoded.height;

    var scaled = decoded;
    if (longest > CloudVisionOcr.maxDimension) {
      scaled = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: CloudVisionOcr.maxDimension)
          : img.copyResize(decoded, height: CloudVisionOcr.maxDimension);
    }

    return base64Encode(img.encodeJpg(scaled, quality: 85));
  } catch (_) {
    return '';
  }
}
