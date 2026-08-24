import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'book_scanner.dart';

// ML Kit reads horizontal text, but book spines are rotated 90°. We run OCR at
// three orientations and keep whichever yields the most characters. Every word
// center is then mapped back to the original frame's X axis for clustering.
enum _Rot { none, cw, ccw }

class OcrResult {
  final List<ScanWord> words;
  final String rotationUsed;
  final String rawText;

  const OcrResult({
    required this.words,
    required this.rotationUsed,
    required this.rawText,
  });
}

class OcrException implements Exception {
  final String message;
  const OcrException(this.message);
  @override
  String toString() => 'OcrException: $message';
}

class OcrService {
  Future<OcrResult> recognize(String imagePath) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    String? cwPath;
    String? ccwPath;
    try {
      // Rotate in a background isolate so the UI thread stays responsive.
      final prep = await compute(_prepareRotations, imagePath);

      final variants = <_Variant>[
        await _ocrVariant(recognizer, imagePath, _Rot.none, 0),
      ];

      if (prep.isNotEmpty) {
        final origWidth = prep['width'] as int;
        cwPath = prep['cw'] as String;
        ccwPath = prep['ccw'] as String;
        variants.add(await _ocrVariant(recognizer, cwPath, _Rot.cw, origWidth));
        variants.add(await _ocrVariant(recognizer, ccwPath, _Rot.ccw, origWidth));
      }

      variants.sort((a, b) => b.charCount.compareTo(a.charCount));
      final best = variants.first;

      debugPrint('[OcrService] orientations → '
          '${variants.map((v) => "${v.label}:${v.charCount}").join(", ")}'
          '  | chose ${best.label}');

      return OcrResult(
        words: best.words,
        rotationUsed: best.label,
        rawText: best.rawText,
      );
    } finally {
      await recognizer.close();
      if (cwPath != null) File(cwPath).delete().ignore();
      if (ccwPath != null) File(ccwPath).delete().ignore();
    }
  }

  Future<_Variant> _ocrVariant(
    TextRecognizer recognizer,
    String path,
    _Rot rot,
    int origWidth,
  ) async {
    final recognized =
        await recognizer.processImage(InputImage.fromFilePath(path));

    final words = <ScanWord>[];
    var charCount = 0;
    var order = 0;

    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final box = element.boundingBox;
          final cx = box.left + box.width / 2;
          final cy = box.top + box.height / 2;

          // Map back to original-frame X. Derivation (angle=90 is clockwise):
          //   as-shot : x = cx
          //   +90° CW : x = cy
          //   −90° CCW: x = (origWidth - 1) - cy
          final double originalX;
          switch (rot) {
            case _Rot.none:
              originalX = cx;
            case _Rot.cw:
              originalX = cy;
            case _Rot.ccw:
              originalX = (origWidth - 1) - cy;
          }

          words.add(ScanWord(text: element.text, centerX: originalX, order: order++));
          charCount += element.text.replaceAll(RegExp(r'\s'), '').length;
        }
      }
    }

    return _Variant(
      words: words,
      charCount: charCount,
      rawText: recognized.text,
      label: switch (rot) {
        _Rot.none => 'as-shot',
        _Rot.cw => '+90°',
        _Rot.ccw => '−90°',
      },
    );
  }
}

class _Variant {
  final List<ScanWord> words;
  final int charCount;
  final String rawText;
  final String label;
  const _Variant({
    required this.words,
    required this.charCount,
    required this.rawText,
    required this.label,
  });
}

({double w, double h}) visibleCropFractions({
  required double screenAspect,
  required double previewAspect,
}) {
  if (screenAspect >= previewAspect) {
    return (w: 1.0, h: previewAspect / screenAspect);
  }
  return (w: screenAspect / previewAspect, h: 1.0);
}

Future<String> cropToVisibleRegion(
  String path,
  double fracW,
  double fracH,
) {
  if (fracW >= 0.999 && fracH >= 0.999) return Future.value(path);
  return compute(_cropCenter, [path, fracW, fracH]);
}

String _cropCenter(List<dynamic> args) {
  final path = args[0] as String;
  final fracW = args[1] as double;
  final fracH = args[2] as double;
  try {
    final decoded = img.decodeImage(File(path).readAsBytesSync());
    if (decoded == null) return path;
    // Bake EXIF orientation so pixel coords match what the preview showed.
    final oriented = img.bakeOrientation(decoded);

    final cw = (oriented.width * fracW).round().clamp(1, oriented.width);
    final ch = (oriented.height * fracH).round().clamp(1, oriented.height);
    final x = ((oriented.width - cw) / 2).round();
    final y = ((oriented.height - ch) / 2).round();

    final cropped = img.copyCrop(oriented, x: x, y: y, width: cw, height: ch);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final out = '${File(path).parent.path}/_scan_crop_$ts.jpg';
    File(out).writeAsBytesSync(img.encodeJpg(cropped, quality: 92));
    return out;
  } catch (_) {
    return path;
  }
}

Map<String, Object> _prepareRotations(String path) {
  try {
    final decoded = img.decodeImage(File(path).readAsBytesSync());
    if (decoded == null) return {};

    final dir = File(path).parent.path;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final cwPath = '$dir/_ocr_cw_$ts.jpg';
    final ccwPath = '$dir/_ocr_ccw_$ts.jpg';

    File(cwPath).writeAsBytesSync(
        img.encodeJpg(img.copyRotate(decoded, angle: 90), quality: 92));
    File(ccwPath).writeAsBytesSync(
        img.encodeJpg(img.copyRotate(decoded, angle: -90), quality: 92));

    return {
      'cw': cwPath,
      'ccw': ccwPath,
      'width': decoded.width,
      'height': decoded.height,
    };
  } catch (_) {
    return {};
  }
}
