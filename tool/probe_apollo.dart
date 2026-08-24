// dart run tool/probe_apollo.dart [--isbn ISBN | --title "Title"]
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const _backend = 'https://catalog.georgetowntexas.gov/catalog/ajax_backend';
const _catalogVersion = '2026-01-16.01';
const _timeout = Duration(seconds: 12);

Future<void> main(List<String> args) async {
  final isbn = _flag(args, '--isbn');
  final title = _flag(args, '--title');
  final query = isbn ?? title ?? "Charlotte's Web";
  final type = isbn != null ? 'isbn' : 'keyword';

  final client = http.Client();
  try {
    final session = await _getSession(client);
    final searchId = await _setupSearch(client, session, type, query);
    final biblioId = await _runSearch(client, session, searchId);
    await _printBiblioInfo(client, session, biblioId);
  } finally {
    client.close();
  }
}

Future<String> _getSession(http.Client client) async {
  print('\n── session_nonlogin ──');
  final resp = await client
      .get(Uri.parse('$_backend/session_nonlogin.xml.pl'))
      .timeout(_timeout);
  _print(resp);
  final token = _attr(resp.body, 'session') ?? _tagText(resp.body, 'session');
  if (token == null) { stderr.writeln('✗ no session token'); exit(1); }
  print('✓ session: ${token.substring(0, 12)}…');
  return token;
}

Future<int> _setupSearch(http.Client client, String session, String type, String query) async {
  print('\n── search_setup ($type: $query) ──');
  final uri = Uri.parse('$_backend/search_setup.xml.pl').replace(
    queryParameters: {'session': session, 'search': '$type:$query'},
  );
  print('GET $uri');
  final resp = await client.get(uri).timeout(_timeout);
  _print(resp);
  final id = int.tryParse(_attr(resp.body, 'search_id') ?? '');
  if (id == null || id == 0) { stderr.writeln('✗ no search_id'); exit(1); }
  print('✓ search_id: $id');
  return id;
}

Future<String> _runSearch(http.Client client, String session, int searchId) async {
  print('\n── perform_search ──');
  final body = jsonEncode({
    'search_id': searchId,
    'catalog_version': _catalogVersion,
    'biblios_only': true,
  });
  print('POST $_backend/perform_search.xml.pl\n$body');
  final resp = await client.post(
    Uri.parse('$_backend/perform_search.xml.pl'),
    headers: {'Content-Type': 'application/json'},
    body: body,
  ).timeout(_timeout);
  _print(resp);
  final id = RegExp(r'<biblio\s+id="(\d+)"').firstMatch(resp.body)?.group(1);
  if (id == null) { stderr.writeln('✗ no biblio id'); exit(1); }
  print('✓ biblio id: $id');
  return id;
}

Future<void> _printBiblioInfo(http.Client client, String session, String biblioId) async {
  print('\n── biblio_info (biblio=$biblioId) ──');
  final uri = Uri.parse('$_backend/biblio_info.xml.pl').replace(
    queryParameters: {'session': session, 'biblio': biblioId},
  );
  print('GET $uri');
  final resp = await client.get(uri).timeout(_timeout);
  print('HTTP ${resp.statusCode}  ${resp.body.length} bytes');
  print(resp.body.replaceAll(RegExp(r'>\s*<'), '>\n<'));
}

void _print(http.Response r) {
  final body = r.body.trim();
  print('HTTP ${r.statusCode}');
  if (body.isEmpty) { print('(empty)'); return; }
  print(body.replaceAll(RegExp(r'>\s*<'), '>\n<').split('\n').map((l) => '  $l').join('\n'));
}

String? _tagText(String xml, String tag) =>
    RegExp('<$tag[^>]*>([^<]+)</$tag>', caseSensitive: false).firstMatch(xml)?.group(1)?.trim();

String? _attr(String xml, String attr) =>
    RegExp('\\b$attr="([^"]+)"', caseSensitive: false).firstMatch(xml)?.group(1)?.trim();

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  return (i != -1 && i + 1 < args.length) ? args[i + 1] : null;
}
