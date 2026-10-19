// dart run tool/probe_z3950.dart [--isbn ISBN | --title "Title" --author "Author" [--call "CALL NO"]]
//
// Only imports pure-Dart files (z3950_client.dart, marc21.dart) — not
// z3950_catalog_service.dart, which pulls in package:flutter and can't run
// outside a Flutter host.
// ignore_for_file: avoid_print

import 'dart:io';
import 'package:shelf_scan/marc21.dart';
import 'package:shelf_scan/z3950_client.dart';

Future<void> main(List<String> args) async {
  final isbn = _flag(args, '--isbn');
  final title = _flag(args, '--title');
  final author = _flag(args, '--author') ?? '';
  final call = _flag(args, '--call');

  if (isbn == null && title == null) {
    print('Usage: dart run tool/probe_z3950.dart --isbn ISBN');
    print('       dart run tool/probe_z3950.dart --title "Title" [--author "Author"] [--call "CALL NO"]');
    exit(64);
  }

  final client = Z3950Client();
  await client.connect();
  print('✓ connected + initialized');

  final hits = isbn != null
      ? await client.searchIsbn(isbn)
      : await client.searchTitleAuthor(title!, author);
  print('✓ hits: $hits');

  if (hits > 0) {
    final records = await client.present(isbn != null ? 1 : 8);
    print('✓ records returned: ${records.length}');
    for (final raw in records) {
      final rec = MarcRecord.parse(raw);
      final t = rec['245'].isNotEmpty ? rec['245'].first.sub('a') : null;
      final a = rec['100'].isNotEmpty ? rec['100'].first.sub('a') : null;
      print('  - $t / $a');
      for (final h in rec['852']) {
        print('      852: u=${h.sub('u')} h=${h.sub('h')} c=${h.sub('c')} 1=${h.sub('1')}');
      }
    }
    if (call != null) print('(spine call number hint: $call — pickBestRecord lives in z3950_catalog_service.dart)');
  }
  await client.close();
}

String? _flag(List<String> args, String name) {
  final i = args.indexOf(name);
  return i == -1 || i + 1 >= args.length ? null : args[i + 1];
}
