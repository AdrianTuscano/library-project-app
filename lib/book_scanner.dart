import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'book_cache.dart';

enum ResultSource {
  network,
  cache,
  unavailable,
}

enum LibraryAvailability {
  available,
  checkedOut,
  unknown,
}

class BookResult {
  final String title;
  final String author;
  final String? firstPublishYear;
  final String? callNumber;
  final String confidence;
  final int position;
  final ResultSource source;
  final LibraryAvailability availability;

  const BookResult({
    required this.title,
    required this.author,
    this.firstPublishYear,
    this.callNumber,
    required this.confidence,
    required this.position,
    this.source = ResultSource.network,
    this.availability = LibraryAvailability.unknown,
  });

  BookResult copyWith({LibraryAvailability? availability}) => BookResult(
        title: title,
        author: author,
        firstPublishYear: firstPublishYear,
        callNumber: callNumber,
        confidence: confidence,
        position: position,
        source: source,
        availability: availability ?? this.availability,
      );

  @override
  String toString() =>
      'Book #$position [$source] {$availability}: "$title" by $author'
      '${firstPublishYear != null ? " ($firstPublishYear)" : ""}';
}

class ScanWord {
  final String text;
  final double centerX;
  final int order;
  ScanWord({required this.text, required this.centerX, this.order = 0});
}

class BookScanner {
  static const _noiseWords = {
    'press', 'books', 'publishing', 'publishers', 'inc', 'ltd', 'co', 'e', 'llc',
    'scholastic', 'penguin', 'puffin', 'random', 'house', 'harper', 'collins',
    'harpercollins', 'simon', 'schuster', 'macmillan', 'hachette', 'bloomsbury',
    'usborne', 'egmont', 'faber', 'walker', 'hodder', 'oxford', 'cambridge',
    'orchard', 'corgi', 'yearling', 'ember', 'delacorte', 'knopf', 'crown',
    'roaring', 'brook', 'square', 'fish', 'little', 'brown', 'hyperion',
    'disney', 'aladdin', 'atheneum', 'greenwillow', 'holt', 'putnam',
  };

  List<List<ScanWord>> clusterByGap(
    List<ScanWord> words, {
    double gapThreshold = 100,
  }) {
    if (words.isEmpty) return [];

    final sorted = List<ScanWord>.from(words)
      ..sort((a, b) => a.centerX.compareTo(b.centerX));

    final clusters = <List<ScanWord>>[];
    var current = [sorted.first];

    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].centerX - sorted[i - 1].centerX > gapThreshold) {
        clusters.add(List.from(current));
        current = [sorted[i]];
      } else {
        current.add(sorted[i]);
      }
    }
    clusters.add(current);

    for (final cluster in clusters) {
      cluster.sort((a, b) => a.order.compareTo(b.order));
    }
    return clusters;
  }

  List<String> filterNoise(List<String> texts) =>
      texts.where((t) => !_noiseWords.contains(t.toLowerCase())).toList();

  String? extractCallNumber(List<String> texts) {
    for (final text in texts) {
      if (RegExp(r'^FIC\s+[A-Z]{3}').hasMatch(text)) return text;
      if (RegExp(r'^\d{3}\.?\d*').hasMatch(text)) return text;
    }
    return null;
  }

  Future<BookResult?> smartBookSearch(
    List<String> texts, {
    String? callNumber,
    int position = 0,
    BookCache? cache,
  }) async {
    final filtered = filterNoise(texts);
    if (filtered.isEmpty) return null;

    final query = _normalizeQuery(filtered);
    if (query.isEmpty) return null;

    if (cache != null) {
      final hit = await cache.lookup(filtered, position);
      if (hit != null) return hit;
    }

    debugPrint('[ShelfScan] query: "$query"');

    BookResult? result;
    try {
      result = await _googleBooks(query, callNumber: callNumber, position: position);
      result ??= await _openLibrary(query, callNumber: callNumber, position: position);
    } on _OfflineException {
      rethrow;
    } catch (e) {
      debugPrint('[ShelfScan] search error: $e');
    }

    if (result != null && cache != null) {
      await cache.store(filtered, result);
    }
    return result;
  }

  String _normalizeQuery(List<String> tokens) {
    return tokens
        .map((t) => t.replaceAll(RegExp(r'[^A-Za-z0-9]'), ' ').trim())
        .where((t) => t.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<BookResult?> _googleBooks(
    String query, {
    String? callNumber,
    int position = 0,
  }) async {
    final uri = Uri.https('www.googleapis.com', '/books/v1/volumes', {
      'q': query,
      'maxResults': '5',
      'printType': 'books',
      'country': 'US',
    });
    final data = await _getJson(uri);
    final items = data?['items'] as List?;
    if (items == null || items.isEmpty) return null;

    Map<String, dynamic>? best;
    var bestScore = -1.0;
    for (final item in items) {
      final vi = (item as Map)['volumeInfo'];
      if (vi is! Map) continue;
      final title = vi['title']?.toString() ?? '';
      final authors = (vi['authors'] as List?)?.join(' ') ?? '';
      final score = _queryOverlap(query, '$title $authors');
      if (score > bestScore) {
        bestScore = score;
        best = vi.cast<String, dynamic>();
      }
    }
    if (best == null || bestScore <= 0) return null;

    return BookResult(
      title: best['title']?.toString() ?? 'Unknown',
      author: (best['authors'] as List?)?.firstOrNull?.toString() ?? 'Unknown',
      firstPublishYear: _extractYear(best['publishedDate']?.toString()),
      callNumber: callNumber,
      confidence: bestScore >= 0.5 ? 'high' : 'medium',
      position: position,
      source: ResultSource.network,
    );
  }

  Future<BookResult?> _openLibrary(
    String query, {
    String? callNumber,
    int position = 0,
  }) async {
    final uri = Uri.https('openlibrary.org', '/search.json', {
      'q': query,
      'limit': '5',
      'fields': 'title,author_name,first_publish_year,numFound',
    });
    final data = await _getJson(uri);
    final docs = data?['docs'] as List?;
    if (docs == null || docs.isEmpty) return null;

    final best = docs.first as Map<String, dynamic>;
    final numFound = (data?['numFound'] as num?)?.toInt() ?? 0;
    return BookResult(
      title: best['title'] as String? ?? 'Unknown',
      author: (best['author_name'] as List?)?.firstOrNull as String? ?? 'Unknown',
      firstPublishYear: best['first_publish_year']?.toString(),
      callNumber: callNumber,
      confidence: numFound < 10 ? 'high' : 'medium',
      position: position,
      source: ResultSource.network,
    );
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    debugPrint('[ShelfScan] GET $uri');
    http.Response res;
    try {
      res = await http.get(uri).timeout(const Duration(seconds: 6));
    } on SocketException catch (e) {
      throw _OfflineException(e.message);
    } on http.ClientException catch (e) {
      throw _OfflineException(e.message);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  double _queryOverlap(String query, String candidate) {
    final queryTokens = _tokenSet(query);
    if (queryTokens.isEmpty) return 0;
    final candidateTokens = _tokenSet(candidate);
    final hits = queryTokens.where(candidateTokens.contains).length;
    return hits / queryTokens.length;
  }

  Set<String> _tokenSet(String s) => s
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.length > 1)
      .toSet();

  String? _extractYear(String? s) {
    if (s == null) return null;
    return RegExp(r'\d{4}').firstMatch(s)?.group(0);
  }

  Future<ScanResult> scanBooks(
    List<ScanWord> words, {
    double gapThreshold = 100,
    BookCache? cache,
    LibraryStatusSource? statusSource,
  }) async {
    final clusters = clusterByGap(words, gapThreshold: gapThreshold);
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

    var books = results.whereType<BookResult>().toList()
      ..sort((a, b) => a.position.compareTo(b.position));

    if (statusSource != null && books.isNotEmpty) {
      try {
        final statuses = await statusSource.statusFor(books);
        books = [
          for (final b in books)
            b.copyWith(availability: statuses[b.position]),
        ];
      } catch (e) {
        debugPrint('[ShelfScan] status lookup failed: $e');
      }
    }

    debugPrint('[ShelfScan] found ${books.length}, offline=$offline');
    for (final b in books) { debugPrint('[ShelfScan] $b'); }

    return ScanResult(books: books, isOffline: offline);
  }
}

class ScanResult {
  final List<BookResult> books;
  final bool isOffline;

  const ScanResult({required this.books, required this.isOffline});
}

class _OfflineException implements Exception {
  final String message;
  const _OfflineException(this.message);
  @override
  String toString() => 'OfflineException: $message';
}

abstract class LibraryStatusSource {
  Future<Map<int, LibraryAvailability>> statusFor(List<BookResult> books);
}

class MockLibraryStatusSource implements LibraryStatusSource {
  const MockLibraryStatusSource();

  @override
  Future<Map<int, LibraryAvailability>> statusFor(List<BookResult> books) async {
    return {
      for (final b in books)
        b.position: b.position % 3 == 0
            ? LibraryAvailability.checkedOut
            : LibraryAvailability.available,
    };
  }
}
