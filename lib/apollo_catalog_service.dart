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

  final _client = http.Client();
  String? _sessionToken;
  DateTime? _sessionExpiresAt;

  @override
  Future<LibraryStatus> checkByIsbn(String isbn) =>
      _withSessionRetry(() async {
        final session = await _freshSession();
        final biblioId = await _findBiblio(session, 'isbn', isbn);
        if (biblioId == null) return const LibraryStatus(status: CircStatus.unknown);
        return _holdingsFor(session, biblioId);
      });

  @override
  Future<LibraryStatus> checkByTitle(String title, String author) =>
      _withSessionRetry(() async {
        final session = await _freshSession();
        final query = [title, author].where((s) => s.isNotEmpty).join(' ');
        final biblioId = await _findBiblio(session, 'keyword', query);
        if (biblioId == null) return const LibraryStatus(status: CircStatus.unknown);
        return _holdingsFor(session, biblioId);
      });

  void dispose() => _client.close();

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

  Future<String?> _findBiblio(String session, String type, String query) async {
    final searchId = await _setupSearch(session, type, query);
    if (searchId == null) return null;
    return _executeSearch(session, searchId);
  }

  Future<int?> _setupSearch(String session, String type, String query) async {
    final uri = Uri.parse('$_backendUrl/search_setup.xml.pl').replace(
      queryParameters: {'session': session, 'search': '$type:$query'},
    );
    final resp = await _client.get(uri).timeout(_requestTimeout);
    _checkForExpiry(resp, 'search_setup');
    _assertOk(resp, 'search_setup');
    return int.tryParse(_xmlAttr(resp.body, 'search_id') ?? '');
  }

  Future<String?> _executeSearch(String session, int searchId) async {
    final body = jsonEncode({
      'search_id': searchId,
      'catalog_version': _catalogVersion,
      'biblios_only': true,
    });
    final resp = await _client.post(
      Uri.parse('$_backendUrl/perform_search.xml.pl'),
      headers: {'Content-Type': 'application/json'},
      body: body,
    ).timeout(_requestTimeout);
    _checkForExpiry(resp, 'perform_search');
    _assertOk(resp, 'perform_search');
    return RegExp(r'<biblio\s+id="(\d+)"', caseSensitive: false)
        .firstMatch(resp.body)
        ?.group(1);
  }

  Future<LibraryStatus> _holdingsFor(String session, String biblioId) async {
    final uri = Uri.parse('$_backendUrl/biblio_info.xml.pl').replace(
      queryParameters: {'session': session, 'biblio': biblioId},
    );
    final resp = await _client.get(uri).timeout(_requestTimeout);
    _checkForExpiry(resp, 'biblio_info');
    _assertOk(resp, 'biblio_info');
    return _statusFromHoldings(resp.body);
  }

  LibraryStatus _statusFromHoldings(String xml) {
    final callNumber = _xmlAttr(xml, 'call') ?? _xmlAttr(xml, 'call_printable');
    final holdingAttrs = RegExp(r'<holding\b([^>]+)>', caseSensitive: false)
        .allMatches(xml)
        .map((m) => m.group(1) ?? '')
        .toList();

    if (holdingAttrs.isEmpty) {
      return LibraryStatus(status: CircStatus.unknown, callNumber: callNumber);
    }
    if (holdingAttrs.any((h) => _xmlAttr(h, 'available') == '1')) {
      return LibraryStatus(status: CircStatus.available, callNumber: callNumber);
    }

    // available="0" with no return_date covers lost/in-transit; still not on shelf.
    final earliestDue = holdingAttrs
        .map((h) => _xmlAttr(h, 'return_date'))
        .where((d) => d != null && d.isNotEmpty)
        .fold<String?>(null, (a, d) => a == null || d!.compareTo(a) < 0 ? d : a);

    return LibraryStatus(
      status: CircStatus.checkedOut,
      callNumber: callNumber,
      dueDate: _formatDueDate(earliestDue),
    );
  }

  static String? _xmlAttr(String xml, String attr) {
    final m = RegExp('\\b$attr="([^"]*)"', caseSensitive: false).firstMatch(xml);
    return m?.group(1)?.trim();
  }

  static String? _formatDueDate(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return null;
    try {
      final d = DateTime.parse(isoDate);
      const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                           'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${months[d.month]} ${d.day}';
    } catch (_) {
      return isoDate;
    }
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

class _SessionExpired implements Exception {
  final String endpoint;
  _SessionExpired(this.endpoint);
}
