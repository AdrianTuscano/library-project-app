// dart run tool/probe_apollo.dart
//
// Walks through the three Apollo ajax_backend steps and prints the raw XML
// at each stage. Run this once to verify endpoint names and field names
// before enabling ApolloLibraryStatusService in the app.
//
// Usage:
//   dart run tool/probe_apollo.dart
//   dart run tool/probe_apollo.dart --isbn 9780062409850
//   dart run tool/probe_apollo.dart --title "Charlotte's Web"

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const _base    = 'https://catalog.georgetowntexas.gov';
const _backend = '$_base/catalog/ajax_backend';

Future<void> main(List<String> args) async {
  final isbn  = _arg(args, '--isbn');
  final title = _arg(args, '--title');
  final query = isbn ?? title ?? 'Charlotte\'s Web';
  final type  = isbn != null ? 'isbn' : 'keyword';

  final client = http.Client();
  try {
    // ── Step 1: Session ──────────────────────────────────────────────────────
    print('\n══ STEP 1: session_nonlogin ══════════════════════════════════════');
    final sessionResp = await client
        .get(Uri.parse('$_backend/session_nonlogin.xml.pl'))
        .timeout(const Duration(seconds: 12));

    _dump(sessionResp);
    final session = _attr(sessionResp.body, 'session')
                 ?? _xml(sessionResp.body, 'session')
                 ?? _xml(sessionResp.body, 'sessionid');
    if (session == null) {
      stderr.writeln('\n✗ Could not find session token. Check tag name above.');
      exit(1);
    }
    print('\n✓ Session token: ${session.substring(0, 12)}…');

    // ── Step 2a: search_setup ────────────────────────────────────────────────
    // search param format: "keyword:Charlotte's Web" or "isbn:9780062409850"
    print('\n══ STEP 2a: search_setup ($type="$query") ═══════════════════════');
    final searchCmd = '$type:$query';
    final setupUri = Uri.parse('$_backend/search_setup.xml.pl').replace(
      queryParameters: {'session': session, 'search': searchCmd},
    );
    print('GET $setupUri\n');
    final setupResp = await client.get(setupUri).timeout(const Duration(seconds: 12));
    _dump(setupResp);

    // search_id is an integer attribute on <root>
    final searchIdStr = _attr(setupResp.body, 'search_id');
    final searchId    = int.tryParse(searchIdStr ?? '');
    if (searchId == null || searchId == 0) {
      stderr.writeln('\n✗ No valid search_id. Raw attr: $searchIdStr');
      exit(1);
    }
    print('\n✓ search_id: $searchId');

    // ── Step 2b: perform_search (JSON POST) ──────────────────────────────────
    print('\n══ STEP 2b: perform_search ══════════════════════════════════════');
    final body = jsonEncode({
      'search_id':       searchId,
      'catalog_version': '2026-01-16.01',
      'biblios_only':    true,
    });
    print('POST $_backend/perform_search.xml.pl\n$body\n');
    final performResp = await client.post(
      Uri.parse('$_backend/perform_search.xml.pl'),
      headers: {'Content-Type': 'application/json'},
      body: body,
    ).timeout(const Duration(seconds: 12));
    _dump(performResp);

    // Results: <biblio id="N"/> — extract first id attr inside a biblio tag
    final biblioMatch = RegExp(r'<biblio\s+id="(\d+)"', caseSensitive: false)
        .firstMatch(performResp.body);
    final biblioStr = biblioMatch?.group(1);
    if (biblioStr == null) {
      stderr.writeln('\n✗ No <biblio id="N"> found. Check XML above.');
      exit(1);
    }
    print('\n✓ First biblio id: $biblioStr');

    // ── Step 3: biblio_info → holdings ───────────────────────────────────────
    print('\n══ STEP 3: biblio_info (biblio=$biblioStr) ══════════════════════');
    final infoUri = Uri.parse('$_backend/biblio_info.xml.pl').replace(
      queryParameters: {'session': session, 'biblio': biblioStr},
    );
    print('GET $infoUri\n');
    final infoResp = await client.get(infoUri).timeout(const Duration(seconds: 12));
    print('HTTP ${infoResp.statusCode}  length=${infoResp.body.length}');
    final fullBody = infoResp.body.replaceAll(RegExp(r'>\s*<'), '>\n<');
    print(fullBody);

    print('\n══ Done ─ check <holding available="…" return_date="…" call="…"/> above.');
  } finally {
    client.close();
  }
}

void _dump(http.Response r) {
  print('HTTP ${r.statusCode}');
  if (r.statusCode != 200) {
    stderr.writeln('Non-200 response — endpoint name may be wrong.');
  }
  // Pretty-print: indent tags for readability.
  final body = r.body.trim();
  if (body.isEmpty) {
    print('(empty body)');
    return;
  }
  // Simple indent: newline before every tag.
  final pretty = body
      .replaceAll(RegExp(r'>\s*<'), '>\n<')
      .split('\n')
      .map((l) => '  $l')
      .join('\n');
  print(pretty);
}

String? _xml(String xml, String tag) {
  final m = RegExp('<$tag[^>]*>([^<]+)</$tag>', caseSensitive: false)
      .firstMatch(xml);
  return m?.group(1)?.trim();
}

// Extracts an attribute value from any tag: session="TOKEN"
String? _attr(String xml, String attr) {
  final m = RegExp('\\b$attr="([^"]+)"', caseSensitive: false).firstMatch(xml);
  return m?.group(1)?.trim();
}

String? _arg(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}
