import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'book_scanner.dart';
import 'ocr_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ClaudeOcr — end-to-end book identification from a shelf photo.
//
// Claude reads the image AND identifies every book in one API call.
// The response is parsed directly into BookResult objects — no Open Library,
// no Google Books, no extra clustering step needed.
// ─────────────────────────────────────────────────────────────────────────────

const _kMaxDim = 2000;

const _kPrompt = '''
You are looking at a photo of a library bookshelf.

Step 1 — Read every spine carefully, left to right, and draft a list of each book as:
Full Title — Author Full Name

Step 2 — Review your draft. For each entry:
- Is this a real published book? Correct any misread spines.
- Include the complete title with subtitle (e.g. "Scrum: The Art of Doing Twice the Work in Half the Time", not just "Scrum").
- Series books often print the series name large and the individual title small — return the individual book title, not just the series name.
- Use the author's full name as it appears on the cover.

Return ONLY the final corrected list — one book per line, leftmost first. Format: Title — Author. No commentary, no numbering, no markdown.
''';

class ClaudeOcr {
  final String apiKey;
  final String model;

  const ClaudeOcr({required this.apiKey, this.model = 'claude-sonnet-4-6'});

  /// Identifies all books in [imagePath] and returns a [ScanResult] directly.
  /// No external book search APIs are used — Claude is the sole source of truth.
  Future<ScanResult> scan(String imagePath) async {
    final b64 = await compute(_encodeImage, imagePath);
    if (b64.isEmpty) throw const OcrException('Could not encode image for Claude');

    final uri = Uri.parse('https://api.anthropic.com/v1/messages');
    final payload = jsonEncode({
      'model': model,
      'max_tokens': 2048,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': b64},
            },
            {'type': 'text', 'text': _kPrompt},
          ],
        }
      ],
    });

    http.Response res;
    try {
      res = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: payload,
      ).timeout(const Duration(seconds: 45));
    } on SocketException catch (e) {
      throw OcrException('Network error: ${e.message}');
    }

    if (res.statusCode != 200) {
      throw OcrException('Claude API ${res.statusCode}: ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final content = (data['content'] as List?)?.first as Map?;
    final rawText = content?['text'] as String? ?? '';

    debugPrint('[ClaudeOcr] raw response:\n$rawText');

    final books = _parseBooks(rawText);
    debugPrint('[ClaudeOcr] identified ${books.length} books');
    for (final b in books) {
      debugPrint('[ClaudeOcr] #${b.position} ${b.title} — ${b.author}');
    }

    if (books.isEmpty) throw const OcrException('Claude found no books in this image');

    return ScanResult(books: books, isOffline: false);
  }

  /// Parse "Title — Author" lines directly into BookResult objects.
  static List<BookResult> _parseBooks(String text) {
    final books = <BookResult>[];
    var position = 1;

    for (final raw in text.trim().split('\n')) {
      final line = raw.replaceAll(RegExp(r'^\s*[-•*\d.]+\s*'), '').trim();
      if (line.isEmpty) continue;

      String title = line;
      String author = '';

      for (final sep in ['—', '--', '–']) {
        if (line.contains(sep)) {
          final parts = line.split(sep);
          title = parts[0].trim();
          author = parts.sublist(1).join(sep).trim();
          break;
        }
      }

      if (title.isEmpty) continue;

      books.add(BookResult(
        title: title,
        author: author,
        confidence: 'high',
        position: position++,
        source: ResultSource.network,
      ));
    }
    return books;
  }
}

// Top-level for compute() — encodes and downscales the image in a background isolate.
String _encodeImage(String path) {
  try {
    final decoded = img.decodeImage(File(path).readAsBytesSync());
    if (decoded == null) return '';

    final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
    final scaled = longest > _kMaxDim
        ? (decoded.width >= decoded.height
            ? img.copyResize(decoded, width: _kMaxDim)
            : img.copyResize(decoded, height: _kMaxDim))
        : decoded;

    return base64Encode(img.encodeJpg(scaled, quality: 90));
  } catch (_) {
    return '';
  }
}
