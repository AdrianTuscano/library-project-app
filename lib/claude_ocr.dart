import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'book_scanner.dart';
import 'ocr_service.dart';

const _maxImageDim = 2000;
const _noBooksFound = 'NO_BOOKS_FOUND';

const _prompt = '''
You are looking at a photo of a library bookshelf.

First, check: can you clearly see book spines in this image? If the image shows something other than books (a wall, a person, a blurry object, an empty shelf, etc.) or if no spines are legible, respond with exactly:
NO_BOOKS_FOUND

Otherwise:

Step 1 — Read every spine carefully, left to right. For each book note:
  a) The full title
  b) The author's full name
  c) The library call number sticker, if one is visible. These are small rectangular labels, usually near the bottom of the spine. Common formats:
     - Fiction: "F" followed by 2–3 letters, e.g. "F SMI" or "F WAL"
     - Juvenile fiction: "JF" followed by letters, e.g. "JF ROW"
     - Non-fiction: a Dewey Decimal number, e.g. "813.54" or "973.7 HAL"
     - Biography: "B" or "BIO" followed by letters
     If no sticker is visible or legible, omit the call number field.

Step 2 — Review your draft. For each entry:
- Is this a real published book? Correct any misread spines.
- Include the complete title with subtitle (e.g. "Scrum: The Art of Doing Twice the Work in Half the Time", not just "Scrum").
- Series books often print the series name large and the individual title small — return the individual book title, not just the series name.
- Use the author's full name as it appears on the cover.
- Double-check the call number sticker text — these are often small and easy to misread.

Return ONLY the final corrected list — one book per line, leftmost first.

Format when call number is visible:   Title — Author — CALL_NUMBER
Format when no call number visible:   Title — Author

No commentary, no numbering, no markdown.
''';

class NoBooksFoundException implements Exception {
  const NoBooksFoundException();
  @override
  String toString() => 'No books found in frame';
}

class ClaudeOcr {
  final String apiKey;
  final String model;

  const ClaudeOcr({required this.apiKey, this.model = 'claude-sonnet-4-6'});

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
            {'type': 'text', 'text': _prompt},
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
    } on TimeoutException {
      throw const OcrException('Request timed out — check your connection');
    }

    if (res.statusCode != 200) {
      debugPrint('[ClaudeOcr] API error ${res.statusCode}: ${res.body}');
      throw OcrException('Claude API error (${res.statusCode})');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final contentList = data['content'] as List?;
    final block = contentList?.firstWhere(
      (b) => (b as Map?)?['type'] == 'text',
      orElse: () => null,
    ) as Map?;
    final rawText = block?['text'] as String? ?? '';

    debugPrint('[ClaudeOcr] raw response:\n$rawText');

    final books = _parseBooks(rawText);
    debugPrint('[ClaudeOcr] identified ${books.length} books');
    for (final b in books) {
      final cn = b.callNumber != null ? ' [${b.callNumber}]' : '';
      debugPrint('[ClaudeOcr] #${b.position} ${b.title} — ${b.author}$cn');
    }

    if (books.isEmpty) throw const OcrException('Claude found no books in this image');

    return ScanResult(books: books, isOffline: false);
  }

  static List<BookResult> _parseBooks(String text) {
    if (text.contains(_noBooksFound)) throw const NoBooksFoundException();

    final books = <BookResult>[];
    var position = 1;

    for (final raw in text.trim().split('\n')) {
      final line = raw.replaceAll(RegExp(r'^\s*[-•*\d.]+\s*'), '').trim();
      if (line.isEmpty) continue;

      String title = line;
      String author = '';
      String? callNumber;

      for (final sep in ['—', '--', '–']) {
        if (line.contains(sep)) {
          final parts = line.split(sep).map((s) => s.trim()).toList();
          title = parts[0];
          author = parts.length > 1 ? parts[1] : '';
          if (parts.length > 2) {
            final raw = parts.sublist(2).join(' ').trim();
            if (raw.isNotEmpty) callNumber = raw;
          }
          break;
        }
      }

      if (title.isEmpty) continue;

      books.add(BookResult(
        title: title,
        author: author,
        callNumber: callNumber,
        confidence: 'high',
        position: position++,
        source: ResultSource.network,
      ));
    }
    return books;
  }
}

String _encodeImage(String path) {
  try {
    final decoded = img.decodeImage(File(path).readAsBytesSync());
    if (decoded == null) return '';

    final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
    final scaled = longest > _maxImageDim
        ? (decoded.width >= decoded.height
            ? img.copyResize(decoded, width: _maxImageDim)
            : img.copyResize(decoded, height: _maxImageDim))
        : decoded;

    return base64Encode(img.encodeJpg(scaled, quality: 90));
  } catch (e) {
    debugPrint('[ClaudeOcr] image encode failed: $e');
    return '';
  }
}
