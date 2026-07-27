import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'book_scanner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// OcrService — multi-orientation text recognition
//
// WHY: Book spine TITLES are printed rotated 90° (you tilt your head to read
// them). ML Kit's Latin recognizer reads horizontal text and largely fails on
// text rotated a full quarter-turn. Running OCR only on the upright frame means
// we typically read just the publisher name (printed horizontally at the foot
// of the spine) and miss the title — the exact symptom we were seeing.
//
// FIX: OCR the captured frame at three orientations — as-shot, +90°, and −90° —
// and keep whichever yields the most text (i.e. the orientation where the
// spine text is closest to horizontal). Whatever rotation wins, every detected
// word's center is mapped back into the ORIGINAL image's coordinate frame, so
// downstream clustering by X-position is unaffected by which rotation we used.
// ─────────────────────────────────────────────────────────────────────────────

enum _Rot { none, cw, ccw }

class OcrResult {
  final List<ScanWord> words; // centers already mapped to original-image X
  final String rotationUsed; // 'as-shot' | '+90°' | '−90°' | 'cloud'
  final String rawText; // full recognized text of the winning orientation

  const OcrResult({
    required this.words,
    required this.rotationUsed,
    required this.rawText,
  });
}

/// Thrown by OCR backends when recognition can't complete (network, decode,
/// API errors). Callers can catch this to fall back to another backend.
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
      // Heavy decode + rotate + re-encode runs off the UI isolate so the
      // shutter doesn't freeze on a 12MP frame.
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

      // Most characters wins = orientation where text is most readable.
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
      _safeDelete(cwPath);
      _safeDelete(ccwPath);
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

          // Map this element's center back into the ORIGINAL frame's X axis.
          // Derivations assume image.copyRotate(angle: 90) is clockwise.
          //   as-shot : originalX = cx
          //   +90° CW : originalX = cy
          //   −90° CCW: originalX = (origWidth - 1) - cy
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

  void _safeDelete(String? path) {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {/* best effort */}
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

// ─────────────────────────────────────────────────────────────────────────────
// Visible-region cropping (keeps scanning WYSIWYG under a full-bleed preview)
// ─────────────────────────────────────────────────────────────────────────────

/// The fraction of the captured frame that's actually visible when the preview
/// is scaled to *cover* the screen. Cover crops the overflow axis; this returns
/// how much width/height survives (centered). One of the two is always 1.0.
({double w, double h}) visibleCropFractions({
  required double screenAspect,
  required double previewAspect,
}) {
  if (screenAspect >= previewAspect) {
    // Screen is wider than the frame → frame fills width, height is cropped.
    return (w: 1.0, h: previewAspect / screenAspect);
  }
  // Screen is taller/narrower → frame fills height, width is cropped.
  return (w: screenAspect / previewAspect, h: 1.0);
}

/// Crops [path] to the centered [fracW]×[fracH] region and returns a new file
/// path. Returns [path] unchanged if no crop is needed or decoding fails.
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
    final out = '${File(path).parent.path}/_scan_crop.jpg';
    File(out).writeAsBytesSync(img.encodeJpg(cropped, quality: 92));
    return out;
  } catch (_) {
    return path;
  }
}

// ─── Runs in a background isolate (top-level for `compute`) ──────────────────
// Decodes the captured frame, writes a +90° and −90° rotated copy next to it,
// and reports the original dimensions needed to map coordinates back.
Map<String, Object> _prepareRotations(String path) {
  try {
    final decoded = img.decodeImage(File(path).readAsBytesSync());
    if (decoded == null) return {};

    final dir = File(path).parent.path;
    final cwPath = '$dir/_ocr_cw.jpg';
    final ccwPath = '$dir/_ocr_ccw.jpg';

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
