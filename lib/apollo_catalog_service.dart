import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'library_status_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ApolloLibraryStatusService
//
// Talks to Georgetown PL's Biblionix Apollo catalog via the same internal
// ajax_backend endpoints the web frontend uses. This is NOT an official API —
// it is the JS app's own backend, reverse-engineered from browser traffic.
//
// HOW TO VERIFY / UPDATE ENDPOINT NAMES
// ──────────────────────────────────────
// 1. Open https://catalog.georgetowntexas.gov in Chrome
// 2. DevTools → Network tab → filter by "ajax_backend"
// 3. Do a search and check the request names/params that appear
// 4. Look at the XML responses to confirm field names
//
// The three-step flow:
//   Step 1 — GET session_nonlogin.xml.pl  → <session>TOKEN</session>
//   Step 2 — GET search.xml.pl?session=...&type=isbn&q=...
//                              OR type=keyword&q=...
//             → first <biblio_id> in results
//   Step 3 — GET biblio_extras.xml.pl?session=...&biblio_id=...
//             → <item> elements with <status> and <due_date>
//
// All errors fall through to CircStatus.unknown so the app degrades
// gracefully if the endpoint changes or the network is unavailable.
// ─────────────────────────────────────────────────────────────────────────────

class ApolloLibraryStatusService implements LibraryStatusService {
  static const _base    = 'https://catalog.georgetowntexas.gov';
  static const _backend = '$_base/catalog/ajax_backend';

  // Session tokens last ~30 min on Apollo; we refresh 5 min early.
  static const _sessionTtl = Duration(minutes: 25);
  static const _timeout    = Duration(seconds: 12);

  final _client = http.Client();
  String?   _session;
  DateTime? _sessionExpiry;

  // ── Public interface ───────────────────────────────────────────────────────

  @override
  Future<LibraryStatus> checkByIsbn(String isbn) async {
    try {
      final session  = await _ensureSession();
      final biblioId = await _searchIsbn(session, isbn);
      if (biblioId == null) return const LibraryStatus(status: CircStatus.unknown);
      return _fetchHoldings(session, biblioId);
    } catch (e) {
      debugPrint('[Apollo] checkByIsbn($isbn): $e');
      return const LibraryStatus(status: CircStatus.unknown);
    }
  }

  @override
  Future<LibraryStatus> checkByTitle(String title, String author) async {
    try {
      final session  = await _ensureSession();
      // Try ISBN search first if we accidentally got one, otherwise keyword.
      final keyword  = [title, author].where((s) => s.isNotEmpty).join(' ');
      final biblioId = await _searchKeyword(session, keyword);
      if (biblioId == null) return const LibraryStatus(status: CircStatus.unknown);
      return _fetchHoldings(session, biblioId);
    } catch (e) {
      debugPrint('[Apollo] checkByTitle("$title"): $e');
      return const LibraryStatus(status: CircStatus.unknown);
    }
  }

  void dispose() => _client.close();

  // ── Step 1: Session ────────────────────────────────────────────────────────

  Future<String> _ensureSession() async {
    if (_session != null &&
        _sessionExpiry != null &&
        DateTime.now().isBefore(_sessionExpiry!)) {
      return _session!;
    }

    // Apollo accepts GET for the guest session endpoint.
    // Observed URL: /catalog/ajax_backend/session_nonlogin.xml.pl
    final resp = await _client
        .get(Uri.parse('$_backend/session_nonlogin.xml.pl'))
        .timeout(_timeout);

    _requireStatus(resp, 'session');

    final token = _xml(resp.body, 'session') ?? _xml(resp.body, 'sessionid');
    if (token == null || token.isEmpty) {
      throw StateError('session_nonlogin returned no token:\n${resp.body}');
    }

    _session       = token;
    _sessionExpiry = DateTime.now().add(_sessionTtl);
    debugPrint('[Apollo] session acquired: ${token.substring(0, 8)}…');
    return token;
  }

  // ── Step 2: Search ─────────────────────────────────────────────────────────

  Future<String?> _searchIsbn(String session, String isbn) async {
    return _search(session, 'isbn', isbn);
  }

  Future<String?> _searchKeyword(String session, String keyword) async {
    return _search(session, 'keyword', keyword);
  }

  Future<String?> _search(String session, String type, String q) async {
    // Observed URL pattern (verify in DevTools):
    //   /catalog/ajax_backend/search.xml.pl
    //   ?session=TOKEN&type=isbn&q=9780062409850
    final uri = Uri.parse('$_backend/search.xml.pl').replace(
      queryParameters: {'session': session, 'type': type, 'q': q},
    );

    final resp = await _client.get(uri).timeout(_timeout);
    if (resp.statusCode == 401) {
      // Session expired mid-flight — clear and let caller retry once.
      _clearSession();
      throw StateError('session expired during search');
    }
    _requireStatus(resp, 'search');

    // Apollo returns a list of results; take the first biblio_id.
    // XML may use biblio_id or biblioId depending on version.
    final id = _xml(resp.body, 'biblio_id') ?? _xml(resp.body, 'biblioId');
    if (id == null) debugPrint('[Apollo] search($type, $q): no results');
    return id;
  }

  // ── Step 3: Holdings ───────────────────────────────────────────────────────

  Future<LibraryStatus> _fetchHoldings(String session, String biblioId) async {
    // Observed URL pattern:
    //   /catalog/ajax_backend/biblio_extras.xml.pl
    //   ?session=TOKEN&biblio_id=12345
    final uri = Uri.parse('$_backend/biblio_extras.xml.pl').replace(
      queryParameters: {'session': session, 'biblio_id': biblioId},
    );

    final resp = await _client.get(uri).timeout(_timeout);
    if (resp.statusCode == 401) {
      _clearSession();
      throw StateError('session expired during biblio_extras');
    }
    _requireStatus(resp, 'biblio_extras');

    return _parseHoldings(resp.body);
  }

  // ── XML → LibraryStatus ────────────────────────────────────────────────────

  LibraryStatus _parseHoldings(String xml) {
    // biblio_extras returns one <item> block per physical copy, e.g.:
    //
    //   <item>
    //     <barcode>31762000123456</barcode>
    //     <call_number>J FIC SMI</call_number>
    //     <status>Available</status>        <!-- or "Checked Out" -->
    //     <due_date>2026-09-10</due_date>   <!-- present when checked out -->
    //     <location>Children's</location>
    //   </item>
    //
    // Field names and status strings are guesses — verify against live XML.

    final callNumber = _xml(xml, 'call_number') ?? _xml(xml, 'callNumber');

    // Walk through every <status> value in the response.
    final statusTags = _xmlAll(xml, 'status');

    // If any copy is explicitly available, report it.
    final anyAvailable = statusTags.any((s) =>
        s.toLowerCase().contains('available') &&
        !s.toLowerCase().contains('not'));
    if (anyAvailable) {
      return LibraryStatus(status: CircStatus.available, callNumber: callNumber);
    }

    // All copies checked out — grab the earliest due date.
    final anyCheckedOut = statusTags.any((s) =>
        s.toLowerCase().contains('checked') ||
        s.toLowerCase().contains('out'));
    if (anyCheckedOut) {
      final rawDue = _xml(xml, 'due_date') ?? _xml(xml, 'dueDate');
      final dueDate = _formatDue(rawDue);
      return LibraryStatus(
        status: CircStatus.checkedOut,
        callNumber: callNumber,
        dueDate: dueDate,
      );
    }

    return LibraryStatus(status: CircStatus.unknown, callNumber: callNumber);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  // Extracts the text content of the first matching XML tag (case-insensitive).
  static String? _xml(String xml, String tag) {
    final m = RegExp(
      '<$tag[^>]*>([^<]+)</$tag>',
      caseSensitive: false,
    ).firstMatch(xml);
    return m?.group(1)?.trim();
  }

  // Extracts ALL occurrences of a tag's text content.
  static List<String> _xmlAll(String xml, String tag) {
    return RegExp('<$tag[^>]*>([^<]+)</$tag>', caseSensitive: false)
        .allMatches(xml)
        .map((m) => m.group(1)?.trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  // Formats an ISO due-date string (2026-09-10) to "Sep 10".
  static String? _formatDue(String? raw) {
    if (raw == null) return null;
    try {
      final d = DateTime.parse(raw.trim());
      const months = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[d.month]} ${d.day}';
    } catch (_) {
      return raw; // Return as-is if format is unexpected.
    }
  }

  void _requireStatus(http.Response resp, String label) {
    if (resp.statusCode != 200) {
      throw StateError('$label returned HTTP ${resp.statusCode}');
    }
  }

  void _clearSession() {
    _session       = null;
    _sessionExpiry = null;
  }
}
