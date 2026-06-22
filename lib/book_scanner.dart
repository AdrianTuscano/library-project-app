import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'book_cache.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data models
// ─────────────────────────────────────────────────────────────────────────────

enum ResultSource {
  network,     // fresh from Open Library
  cache,       // served from local SQLite
  unavailable, // no network AND no cache hit — shows raw OCR text
}

class BookResult {
  final String title;
  final String author;
  final String? firstPublishYear;
  final String? callNumber;
  final String confidence; // 'high' | 'medium'
  final int position;
  final ResultSource source;

  const BookResult({
    required this.title,
    required this.author,
    this.firstPublishYear,
    this.callNumber,
    required this.confidence,
    required this.position,
    this.source = ResultSource.network,
  });

  @override
  String toString() =>
      'Book #$position [$source]: "$title" by $author'
      '${firstPublishYear != null ? " ($firstPublishYear)" : ""}';
}

class ScanWord {
  final String text;
  final double centerX;
  ScanWord({required this.text, required this.centerX});
}

// ─────────────────────────────────────────────────────────────────────────────
// BookScanner
// ─────────────────────────────────────────────────────────────────────────────

class BookScanner {
  static const _noiseWords = {
    'press', 'books', 'publishing', 'inc', 'ltd', 'co', 'e',
  };

  // ── 1. Spatial clustering ─────────────────────────────────────────────────

  List<ScanWord> _extractWords(RecognizedText recognizedText) {
    final words = <ScanWord>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final box = element.boundingBox;
          words.add(ScanWord(
            text: element.text,
            centerX: box.left + box.width / 2,
          ));
        }
      }
    }
    return words;
  }

  /// Split words into per-spine clusters by X-position gap.
  /// Default 20 px matched the Pi; phone resolution may need 50–100.
  List<List<ScanWord>> clusterByGap(
    RecognizedText recognizedText, {
    double gapThreshold = 20,
  }) {
    final words = _extractWords(recognizedText);
    if (words.isEmpty) return [];

    words.sort((a, b) => a.centerX.compareTo(b.centerX));

    final clusters = <List<ScanWord>>[];
    var current = [words.first];

    for (var i = 1; i < words.length; i++) {
      if (words[i].centerX - words[i - 1].centerX > gapThreshold) {
        clusters.add(List.from(current));
        current = [words[i]];
      } else {
        current.add(words[i]);
      }
    }
    clusters.add(current);
    return clusters;
  }

  // ── 2. Noise filtering ────────────────────────────────────────────────────

  List<String> filterNoise(List<String> texts) =>
      texts.where((t) => !_noiseWords.contains(t.toLowerCase())).toList();

  // ── 3. Call number extraction ─────────────────────────────────────────────

  String? extractCallNumber(List<String> texts) {
    for (final text in texts) {
      if (RegExp(r'^FIC\s+[A-Z]{3}').hasMatch(text)) return text;
      if (RegExp(r'^\d{3}\.?\d*').hasMatch(text)) return text;
    }
    return null;
  }

  // ── 4. Smart Open Library search ──────────────────────────────────────────

  /// Returns a [BookResult] or null (book genuinely not found).
  /// Throws [_OfflineException] when connectivity fails so [scanBooks] can
  /// distinguish "not found" from "can't reach network".
  Future<BookResult?> smartBookSearch(
    List<String> texts, {
    String? callNumber,
    int position = 0,
    BookCache? cache,
  }) async {
    final filtered = filterNoise(texts);
    if (filtered.isEmpty) return null;

    // Cache check first — works fully offline.
    if (cache != null) {
      final hit = await cache.lookup(filtered, position);
      if (hit != null) return hit;
    }

    // Strategy 1: combined q= search.
    final combined = filtered.join(' ');
    final uri1 = Uri.https('openlibrary.org', '/search.json', {'q': combined});
    debugPrint('[ShelfScan] S1 → $uri1');

    BookResult? result;
    try {
      result = await _fetch(uri1, callNumber: callNumber, position: position);
    } on _OfflineException {
      rethrow; // propagate so scanBooks can set offline flag
    } catch (e) {
      debugPrint('[ShelfScan] S1 error: $e');
    }

    // Strategy 2: title + author fallback.
    if (result == null) {
      final byLength = List<String>.from(filtered)
        ..sort((a, b) => b.length.compareTo(a.length));
      final params = <String, String>{'title': byLength.first};
      if (byLength.length > 1) params['author'] = byLength[1];

      final uri2 = Uri.https('openlibrary.org', '/search.json', params);
      debugPrint('[ShelfScan] S2 → $uri2');

      try {
        result = await _fetch(
          uri2,
          callNumber: callNumber,
          position: position,
          forceConfidence: 'medium',
        );
      } on _OfflineException {
        rethrow;
      } catch (e) {
        debugPrint('[ShelfScan] S2 error: $e');
      }
    }

    // Cache the successful network result for future offline use.
    if (result != null && cache != null) {
      await cache.store(filtered, result);
    }

    return result;
  }

  Future<BookResult?> _fetch(
    Uri uri, {
    required String? callNumber,
    required int position,
    String? forceConfidence,
  }) async {
    http.Response res;
    try {
      res = await http.get(uri).timeout(const Duration(seconds: 6));
    } on SocketException catch (e) {
      throw _OfflineException(e.message);
    } on http.ClientException catch (e) {
      throw _OfflineException(e.message);
    }
    // Non-2xx or empty body → treat as "not found", not offline.
    if (res.statusCode < 200 || res.statusCode >= 300) return null;

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final docs = data['docs'] as List?;
    if (docs == null || docs.isEmpty) return null;

    final best = docs.first as Map<String, dynamic>;
    final numFound = (data['numFound'] as num?)?.toInt() ?? 0;
    return BookResult(
      title: best['title'] as String? ?? 'Unknown',
      author: (best['author_name'] as List?)?.firstOrNull as String? ?? 'Unknown',
      firstPublishYear: best['first_publish_year']?.toString(),
      callNumber: callNumber,
      confidence: forceConfidence ?? (numFound < 10 ? 'high' : 'medium'),
      position: position,
      source: ResultSource.network,
    );
  }

  // ── 5. Full pipeline ──────────────────────────────────────────────────────

  Future<ScanResult> scanBooks(
    RecognizedText recognizedText, {
    double gapThreshold = 20,
    BookCache? cache,
  }) async {
    final clusters = clusterByGap(recognizedText, gapThreshold: gapThreshold);
    debugPrint('[ShelfScan] clusters: ${clusters.length}');
    if (clusters.isEmpty) return const ScanResult(books: [], isOffline: false);

    for (var i = 0; i < clusters.length; i++) {
      debugPrint('[ShelfScan] cluster ${i + 1}: ${clusters[i].map((w) => w.text).toList()}');
    }

    bool offline = false;

    final futures = clusters.asMap().entries.map((entry) async {
      final idx = entry.key;
      final cluster = entry.value;
      final texts = cluster.map((w) => w.text).toList();
      final callNumber = extractCallNumber(texts);

      try {
        return await smartBookSearch(
          texts,
          callNumber: callNumber,
          position: idx + 1,
          cache: cache,
        );
      } on _OfflineException catch (e) {
        debugPrint('[ShelfScan] offline: $e');
        offline = true;
        // Return best-effort: raw cluster text so card still shows something.
        final filtered = filterNoise(texts);
        return BookResult(
          title: filtered.isNotEmpty ? filtered.join(' ') : texts.join(' '),
          author: '',
          callNumber: callNumber,
          confidence: 'medium',
          position: idx + 1,
          source: ResultSource.unavailable,
        );
      } catch (e) {
        debugPrint('[ShelfScan] cluster ${idx + 1} error: $e');
        return null;
      }
    }).toList();

    final results = await Future.wait(futures);

    final books = results.whereType<BookResult>().toList()
      ..sort((a, b) => a.position.compareTo(b.position));

    debugPrint('[ShelfScan] found ${books.length}, offline=$offline');
    for (final b in books) debugPrint('[ShelfScan] $b');

    return ScanResult(books: books, isOffline: offline);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Supporting types
// ─────────────────────────────────────────────────────────────────────────────

class ScanResult {
  final List<BookResult> books;
  final bool isOffline; // true = at least one cluster hit the network error path

  const ScanResult({required this.books, required this.isOffline});
}

class _OfflineException implements Exception {
  final String message;
  const _OfflineException(this.message);
  @override
  String toString() => 'OfflineException: $message';
}
