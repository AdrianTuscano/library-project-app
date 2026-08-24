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
    final session = _xml(sessionResp.body, 'session')
                 ?? _xml(sessionResp.body, 'sessionid');
    if (session == null) {
      stderr.writeln('\n✗ Could not find session token. Check tag name above.');
      exit(1);
    }
    print('\n✓ Session token: ${session.substring(0, 12)}…');

    // ── Step 2: Search ───────────────────────────────────────────────────────
    print('\n══ STEP 2: search ($type="$query") ══════════════════════════════');
    final searchUri = Uri.parse('$_backend/search.xml.pl').replace(
      queryParameters: {'session': session, 'type': type, 'q': query},
    );
    print('GET $searchUri\n');
    final searchResp = await client
        .get(searchUri)
        .timeout(const Duration(seconds: 12));

    _dump(searchResp);
    final biblioId = _xml(searchResp.body, 'biblio_id')
                  ?? _xml(searchResp.body, 'biblioId');
    if (biblioId == null) {
      stderr.writeln('\n✗ No biblio_id found. Check tag name above.');
      exit(1);
    }
    print('\n✓ First biblio_id: $biblioId');

    // ── Step 3: Holdings ─────────────────────────────────────────────────────
    print('\n══ STEP 3: biblio_extras (biblio_id=$biblioId) ══════════════════');
    final extrasUri = Uri.parse('$_backend/biblio_extras.xml.pl').replace(
      queryParameters: {'session': session, 'biblio_id': biblioId},
    );
    print('GET $extrasUri\n');
    final extrasResp = await client
        .get(extrasUri)
        .timeout(const Duration(seconds: 12));

    _dump(extrasResp);
    print('\n══ Done — update apollo_catalog_service.dart with correct field names above.');
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

String? _arg(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}
