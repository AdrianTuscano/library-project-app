import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'library_status_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ApolloLibraryStatusService
//
// Talks to Georgetown PL's Biblionix Apollo catalog via the same internal
// ajax_backend endpoints the web frontend uses. Reverse-engineered from
// browser traffic and verified against live responses (2026-07).
//
// VERIFIED four-step flow:
//
//   Step 1 — GET session_nonlogin.xml.pl
//             → <root session="TOKEN" …/>   (attribute, not child element)
//
//   Step 2a — GET search_setup.xml.pl?session=S&search=keyword:QUERY
//                                             OR search=isbn:ISBN
//              → <root search_id="N">…</root>   (integer attribute)
//
//   Step 2b — POST perform_search.xml.pl
//              body: {"search_id":N,"catalog_version":"2026-01-16.01","biblios_only":true}
//              → <root><biblio id="N"/><biblio id="N"/>…</root>
//
//   Step 3  — GET biblio_info.xml.pl?session=S&biblio=N
//              → rich XML with <holding> elements, one per physical copy:
//                <holding … available="1|0" return_date="YYYY-MM-DD|" call="JF WHIT" …/>
//
// NOTE: biblio_extras.xml.pl always returns HTTP 500 for Georgetown
//       (data_provider="unbound"). Do NOT call it.
//
// catalog_version string is baked into Apollo's JS bundle. If searches start
// returning 0 results, re-scrape the bundle for a newer value.
// ─────────────────────────────────────────────────────────────────────────────

class ApolloLibraryStatusService implements LibraryStatusService {
  static const _base    = 'https://catalog.georgetowntexas.gov';
  static const _backend = '$_base/catalog/ajax_backend';
  static const _catalogVersion = '2026-01-16.01';

  // Session tokens last ~30 min on Apollo; we refresh 5 min early.
  static const _sessionTtl = Duration(minutes: 25);
  static const _timeout    = Duration(seconds: 12);

  final _client = http.Client();
  String?   _session;
  DateTime? _sessionExpiry;

  // ── Public interface ───────────────────────────────────────────────────────

  @override
  Future<LibraryStatus> checkByIsbn(String isbn) =>
      _withRetry(() async {
        final session  = await _ensureSession();
        final biblioId = await _search(session, 'isbn', isbn);
        if (biblioId == null) return const LibraryStatus(status: CircStatus.unknown);
        return _fetchHoldings(session, biblioId);
      }, tag: 'checkByIsbn($isbn)');

  @override
  Future<LibraryStatus> checkByTitle(String title, String author) =>
      _withRetry(() async {
        final session  = await _ensureSession();
        final keyword  = [title, author].where((s) => s.isNotEmpty).join(' ');
        final biblioId = await _search(session, 'keyword', keyword);
        if (biblioId == null) return const LibraryStatus(status: CircStatus.unknown);
        return _fetchHoldings(session, biblioId);
      }, tag: 'checkByTitle("$title")');

  // Retries once on session-expired errors, falls back to unknown on all others.
  Future<LibraryStatus> _withRetry(
    Future<LibraryStatus> Function() fn, {
    required String tag,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await fn();
      } on StateError catch (e) {
        if (e.message.contains('session expired') && attempt == 0) {
          debugPrint('[Apollo] $tag: session expired, refreshing…');
          _clearSession();
          continue;
        }
        debugPrint('[Apollo] $tag: $e');
        return const LibraryStatus(status: CircStatus.unknown);
      } catch (e) {
        debugPrint('[Apollo] $tag: $e');
        return const LibraryStatus(status: CircStatus.unknown);
      }
    }
    return const LibraryStatus(status: CircStatus.unknown);
  }

  void dispose() => _client.close();

  // ── Step 1: Session ────────────────────────────────────────────────────────

  Future<String> _ensureSession() async {
    if (_session != null &&
        _sessionExpiry != null &&
        DateTime.now().isBefore(_sessionExpiry!)) {
      return _session!;
    }

    final resp = await _client
        .get(Uri.parse('$_backend/session_nonlogin.xml.pl'))
        .timeout(_timeout);
    _requireOk(resp, 'session_nonlogin');

    // Token is an XML attribute: <root session="TOKEN" …/>
    final token = _attr(resp.body, 'session');
    if (token == null || token.isEmpty) {
      throw StateError('session_nonlogin returned no token:\n${resp.body}');
    }

    _session       = token;
    _sessionExpiry = DateTime.now().add(_sessionTtl);
    debugPrint('[Apollo] session acquired: ${token.substring(0, 8)}…');
    return token;
  }

  // ── Step 2: Two-step search → biblio id ───────────────────────────────────

  Future<String?> _search(String session, String type, String q) async {
    // 2a: search_setup → search_id
    final setupUri = Uri.parse('$_backend/search_setup.xml.pl').replace(
      queryParameters: {'session': session, 'search': '$type:$q'},
    );
    final setupResp = await _client.get(setupUri).timeout(_timeout);
    if (setupResp.statusCode == 401) {
      _clearSession();
      throw StateError('session expired during search_setup');
    }
    _requireOk(setupResp, 'search_setup');

    final searchIdStr = _attr(setupResp.body, 'search_id');
    final searchId    = int.tryParse(searchIdStr ?? '');
    if (searchId == null || searchId == 0) {
      debugPrint('[Apollo] search($type, $q): no search_id');
      return null;
    }

    // 2b: perform_search → first biblio id
    final body = jsonEncode({
      'search_id':       searchId,
      'catalog_version': _catalogVersion,
      'biblios_only':    true,
    });
    final performResp = await _client.post(
      Uri.parse('$_backend/perform_search.xml.pl'),
      headers: {'Content-Type': 'application/json'},
      body: body,
    ).timeout(_timeout);
    if (performResp.statusCode == 401) {
      _clearSession();
      throw StateError('session expired during perform_search');
    }
    _requireOk(performResp, 'perform_search');

    final m = RegExp(r'<biblio\s+id="(\d+)"', caseSensitive: false)
        .firstMatch(performResp.body);
    if (m == null) {
      debugPrint('[Apollo] search($type, $q): no results');
      return null;
    }
    return m.group(1);
  }

  // ── Step 3: biblio_info → holdings ────────────────────────────────────────

  Future<LibraryStatus> _fetchHoldings(String session, String biblioId) async {
    final uri = Uri.parse('$_backend/biblio_info.xml.pl').replace(
      queryParameters: {'session': session, 'biblio': biblioId},
    );
    final resp = await _client.get(uri).timeout(_timeout);
    if (resp.statusCode == 401) {
      _clearSession();
      throw StateError('session expired during biblio_info');
    }
    _requireOk(resp, 'biblio_info');
    return _parseHoldings(resp.body);
  }

  // ── XML → LibraryStatus ────────────────────────────────────────────────────

  LibraryStatus _parseHoldings(String xml) {
    // biblio_info returns one <holding> element per physical copy, e.g.:
    //
    //   <holding id="591525140"
    //            available="1"          ← 1=on shelf, 0=not available
    //            return_date=""         ← ISO date when checked out, else ""
    //            call="JF WHIT"        ← call number
    //            location_printable="1st Floor Children's Room — JF WHIT"
    //            branch_printable="Georgetown"
    //            …/>

    // Call number from first holding, fall back to shelf_location attribute.
    final callNumber =
        _attr(xml, 'call') ??
        _attr(xml, 'call_printable');

    // Walk every <holding> and collect available flags + return dates.
    final holdings = RegExp(
      r'<holding\b([^>]+)>',
      caseSensitive: false,
    ).allMatches(xml).map((m) => m.group(1) ?? '').toList();

    if (holdings.isEmpty) {
      return LibraryStatus(status: CircStatus.unknown, callNumber: callNumber);
    }

    // Any copy with available="1" → report available immediately.
    final anyAvailable = holdings.any((h) => _attrIn(h, 'available') == '1');
    if (anyAvailable) {
      return LibraryStatus(status: CircStatus.available, callNumber: callNumber);
    }

    // All copies unavailable — find earliest non-empty return_date.
    String? earliestDue;
    for (final h in holdings) {
      final raw = _attrIn(h, 'return_date');
      if (raw != null && raw.isNotEmpty) {
        if (earliestDue == null || raw.compareTo(earliestDue) < 0) {
          earliestDue = raw;
        }
      }
    }

    // available="0" with no return_date could be lost, in-transit, etc.
    // Still treat as checked-out since the book is not on the shelf.
    return LibraryStatus(
      status: CircStatus.checkedOut,
      callNumber: callNumber,
      dueDate: _formatDue(earliestDue),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  // Extracts an XML attribute from the full document: attr="VALUE"
  static String? _attr(String xml, String attr) {
    final m = RegExp('\\b$attr="([^"]*)"', caseSensitive: false).firstMatch(xml);
    return m?.group(1)?.trim();
  }

  // Extracts an attribute from a single tag's attribute string snippet.
  static String? _attrIn(String attrs, String attr) {
    final m = RegExp('\\b$attr="([^"]*)"', caseSensitive: false).firstMatch(attrs);
    return m?.group(1);
  }

  // Formats an ISO due-date string (YYYY-MM-DD) to "Sep 10".
  static String? _formatDue(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final d = DateTime.parse(raw.trim());
      const months = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[d.month]} ${d.day}';
    } catch (_) {
      return raw;
    }
  }

  void _requireOk(http.Response resp, String label) {
    if (resp.statusCode != 200) {
      throw StateError('$label returned HTTP ${resp.statusCode}');
    }
  }

  void _clearSession() {
    _session       = null;
    _sessionExpiry = null;
  }
}
