// ─────────────────────────────────────────────────────────────────────────────
// LibraryStatusService backed by a Biblionix library's Z39.50 server —
// Biblionix's own suggested, sanctioned replacement for the Apollo
// ajax_backend scraper. Which library is Settings > Library (see
// CatalogLibrary in settings.dart) — same protocol, same real-time-status
// trick, just a different database name per library.
// See docs/catalog-integration-plan.md and docs/library-connection-roadmap.md.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'library_status_service.dart';
import 'marc21.dart';
import 'settings.dart';
import 'z3950_client.dart';

void _log(String msg) => debugPrint('[Z3950Service] $msg');

class Z3950LibraryStatusService implements LibraryStatusService {
  /// Keyword searches can surface several editions/formats of the same
  /// title (hardcover, large print, audiobook, Libby ebook…); look at a
  /// few candidates and pick the one that matches the spine's call number.
  static const _maxTitleCandidates = 8;
  static const _timeout = Duration(seconds: 15);

  Z3950Client _newClient() => Z3950Client(database: appSettings.library.database);

  @override
  Future<LibraryStatus> checkByIsbn(String isbn) => _guarded('checkByIsbn($isbn)', () async {
        final digits = isbn.replaceAll(RegExp(r'[^0-9Xx]'), '');
        final client = _newClient();
        try {
          await client.connect();
          final hits = await client.searchIsbn(digits);
          if (hits == 0) {
            _log('checkByIsbn($isbn): 0 hits -> unknown');
            return const LibraryStatus(status: CircStatus.unknown);
          }
          final records = await client.present(1);
          if (records.isEmpty) {
            _log('checkByIsbn($isbn): present() returned no records -> unknown');
            return const LibraryStatus(status: CircStatus.unknown);
          }
          final status = _statusFromRecord(MarcRecord.parse(records.first));
          _log('checkByIsbn($isbn) -> ${status.status}, callNumber=${status.callNumber}');
          return status;
        } finally {
          await client.close();
        }
      });

  @override
  Future<LibraryStatus> checkByTitle(String title, String author, {String? callNumber}) => _guarded(
      'checkByTitle("$title", "$author", callNumber: $callNumber)', () async {
        final client = _newClient();
        try {
          await client.connect();
          final hits = await client.searchTitleAuthor(title, author);
          if (hits == 0) {
            _log('checkByTitle("$title"): 0 hits -> unknown');
            return const LibraryStatus(status: CircStatus.unknown);
          }
          final raw = await client.present(_maxTitleCandidates);
          final records = raw.map(MarcRecord.parse).toList();
          final best = _pickBestRecord(records, callNumber);
          if (best == null) {
            _log('checkByTitle("$title"): no record had a shelf holding -> unknown');
            return const LibraryStatus(status: CircStatus.unknown);
          }
          final status = _statusFromRecord(best);
          _log('checkByTitle("$title") -> ${status.status}, callNumber=${status.callNumber}');
          return status;
        } finally {
          await client.close();
        }
      });

  Future<LibraryStatus> _guarded(String what, Future<LibraryStatus> Function() fn) async {
    try {
      return await fn().timeout(_timeout, onTimeout: () {
        _log('$what: TIMED OUT after $_timeout (connect/search/present never finished)');
        throw TimeoutException(what);
      });
    } catch (e, st) {
      _log('$what FAILED: $e');
      if (e is! TimeoutException) _log('$what stack: $st');
      return const LibraryStatus(status: CircStatus.unknown);
    }
  }

  /// Picks the record most likely to be the physical copy that was
  /// scanned: must have at least one shelf holding (so a Libby-only
  /// ebook/audiobook record loses to a print one), then prefers whichever
  /// holding's call number matches the spine sticker, if we read one.
  static MarcRecord? _pickBestRecord(List<MarcRecord> records, String? spineCall) {
    final spine = _normalizeCall(spineCall);
    final spinePrefix = spine.split(' ').first;
    MarcRecord? best;
    var bestScore = -1;
    for (final rec in records) {
      final holdings = rec['852'];
      if (holdings.isEmpty) continue;
      final calls = holdings.map(_callNumberOf).where((c) => c.isNotEmpty).map(_normalizeCall).toList();
      var score = 0;
      if (spine.isNotEmpty) {
        if (calls.any((c) => c.startsWith(spine) || spine.startsWith(c))) {
          score += 4;
        } else if (calls.any((c) => c.split(' ').first == spinePrefix)) {
          score += 3; // same collection, different cutter
        }
      }
      if (score > bestScore) {
        best = rec;
        bestScore = score;
      }
    }
    // No spine match beat another — fall back to the top catalog-relevance
    // hit rather than finding nothing.
    return best ?? records.firstWhereOrNull((r) => r['852'].isNotEmpty);
  }

  static LibraryStatus _statusFromRecord(MarcRecord rec) {
    final holdings = rec['852'];
    if (holdings.isEmpty) return const LibraryStatus(status: CircStatus.unknown);
    final callNumber = _callNumberOf(holdings.first);
    final status = holdings.any((h) => h.sub('1') == 'In')
        ? CircStatus.available
        : holdings.any((h) => h.sub('1') == 'Out')
            ? CircStatus.checkedOut
            : CircStatus.unknown;
    return LibraryStatus(status: status, callNumber: callNumber.isEmpty ? null : callNumber);
  }

  /// Collection code ($u) + cutter ($h), e.g. "JCDBK WHIT" — matches the
  /// sticker format the OCR prompt asks for.
  static String _callNumberOf(MarcField holding) {
    final parts = [holding.sub('u') ?? '', holding.sub('h') ?? ''].where((s) => s.isNotEmpty);
    return parts.join(' ');
  }

  static String _normalizeCall(String? call) =>
      (call ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9.]+'), ' ').trim();
}

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
