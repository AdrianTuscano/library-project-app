import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'library_status_service.dart';

class ApolloLibraryStatusService implements LibraryStatusService {
  static const _backendUrl = 'https://catalog.georgetowntexas.gov/catalog/ajax_backend';
  static const _catalogVersion = '2026-01-16.01';
  // Apollo sessions last ~30 min; refresh 5 min early to avoid mid-request expiry.
  static const _sessionLifetime = Duration(minutes: 25);
  static const _requestTimeout = Duration(seconds: 12);
  // Keyword results mix formats (DVD, audiobook, Libby) ahead of the print
  // book, so we look at the top few and pick one.
  static const _maxResults = 8;

  final _client = http.Client();
  String? _sessionToken;
  DateTime? _sessionExpiresAt;

  @override
  Future<LibraryStatus> checkByIsbn(String isbn) => _lookup('isbn:$isbn');

  @override
  Future<LibraryStatus> checkByTitle(String title, String author, {String? callNumber}) =>
      _lookup('keyword:${[title, author].where((s) => s.isNotEmpty).join(' ')}', callNumber);

  void dispose() => _client.close();

  /// Full search results already carry each record's format, call number and
  /// per-copy availability, so a lookup is just search_setup + perform_search.
  Future<LibraryStatus> _lookup(String search, [String? spineCall]) =>
      _withSessionRetry(() async {
        final session = await _freshSession();
        final searchId = await _setupSearch(session, search);
        if (searchId == null) return const LibraryStatus(status: CircStatus.unknown);
        final best = _pickBest(await _performSearch(session, searchId), spineCall);
        if (best == null) return const LibraryStatus(status: CircStatus.unknown);
        return LibraryStatus(
          status: best.copies.contains(true) ? CircStatus.available : CircStatus.checkedOut,
          callNumber: best.call.isEmpty ? null : best.call,
        );
      });

  Future<LibraryStatus> _withSessionRetry(Future<LibraryStatus> Function() fn) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await fn();
      } on _SessionExpired {
        if (attempt > 0) break;
        _expireSession();
      } catch (e) {
        debugPrint('[Apollo] $e');
        break;
      }
    }
    return const LibraryStatus(status: CircStatus.unknown);
  }

  Future<String> _freshSession() async {
    final now = DateTime.now();
    if (_sessionToken != null && _sessionExpiresAt != null && now.isBefore(_sessionExpiresAt!)) {
      return _sessionToken!;
    }
    final resp = await _client
        .get(Uri.parse('$_backendUrl/session_nonlogin.xml.pl'))
        .timeout(_requestTimeout);
    _assertOk(resp, 'session_nonlogin');
    final token = _xmlAttr(resp.body, 'session');
    if (token == null || token.isEmpty) throw StateError('no session token in response');
    _sessionToken = token;
    _sessionExpiresAt = now.add(_sessionLifetime);
    return token;
  }

  Future<int?> _setupSearch(String session, String search) async {
    final uri = Uri.parse('$_backendUrl/search_setup.xml.pl').replace(
      queryParameters: {'session': session, 'search': search},
    );
    final resp = await _client.get(uri).timeout(_requestTimeout);
    _checkForExpiry(resp, 'search_setup');
    _assertOk(resp, 'search_setup');
    return int.tryParse(_xmlAttr(resp.body, 'search_id') ?? '');
  }

  Future<List<_Record>> _performSearch(String session, int searchId) async {
    final resp = await _client.post(
      Uri.parse('$_backendUrl/perform_search.xml.pl'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'search_id': searchId,
        'catalog_version': _catalogVersion,
        'max_results': _maxResults,
      }),
    ).timeout(_requestTimeout);
    _checkForExpiry(resp, 'perform_search');
    _assertOk(resp, 'perform_search');
    return _parseResults(resp.body);
  }

  /// Each result is `<s b=… m="medium" c="call number" …>` followed by its
  /// holdings as `<h … available="0|1" …>`.
  static List<_Record> _parseResults(String xml) =>
      xml.split('<s ').skip(1).map(_parseRecord).toList();

  static _Record _parseRecord(String seg) {
    final end = seg.indexOf('>');
    final head = end < 0 ? seg : seg.substring(0, end);
    return _Record(
      call: _xmlAttr(head, 'c') ?? '',
      isPrint: (_xmlAttr(head, 'm') ?? '').isEmpty,
      copies: RegExp(r'<h\b[^>]*\bavailable="([01])"')
          .allMatches(seg)
          .map((m) => m.group(1) == '1')
          .toList(),
    );
  }

  /// Picks the record most likely to be the physical book on the shelf.
  /// Ties keep catalog relevance order.
  static _Record? _pickBest(List<_Record> records, String? spineCall) {
    final spine = _normalizeCall(spineCall);
    final spinePrefix = spine.split(' ').first;
    _Record? best;
    var bestScore = -1;
    for (final r in records) {
      // No physical copies (e.g. Libby eBooks/audiobooks) — can't be what was scanned.
      if (r.copies.isEmpty) continue;
      // Print books carry no medium; DVDs, CDs, talking books, large print do.
      var score = r.isPrint ? 2 : 0;
      final call = _normalizeCall(r.call);
      if (spine.isNotEmpty && call.isNotEmpty) {
        if (call.startsWith(spine) || spine.startsWith(call)) {
          score += 4;
        } else if (call.split(' ').first == spinePrefix) {
          score += 3; // same collection (JF, JDVD, LPF…), different cutter
        }
      }
      if (score > bestScore) {
        best = r;
        bestScore = score;
      }
    }
    return best;
  }

  static String _normalizeCall(String? call) =>
      (call ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9.]+'), ' ').trim();

  static String? _xmlAttr(String xml, String attr) {
    final m = RegExp('\\b$attr="([^"]*)"', caseSensitive: false).firstMatch(xml);
    return m?.group(1)?.trim();
  }

  void _assertOk(http.Response resp, String endpoint) {
    if (resp.statusCode != 200) throw StateError('$endpoint → HTTP ${resp.statusCode}');
  }

  void _checkForExpiry(http.Response resp, String endpoint) {
    if (resp.statusCode == 401) {
      _expireSession();
      throw _SessionExpired(endpoint);
    }
  }

  void _expireSession() {
    _sessionToken = null;
    _sessionExpiresAt = null;
  }
}

class _Record {
  final String call;
  final bool isPrint;
  final List<bool> copies; // availability of each physical copy
  const _Record({required this.call, required this.isPrint, required this.copies});
}

class _SessionExpired implements Exception {
  final String endpoint;
  _SessionExpired(this.endpoint);
}
