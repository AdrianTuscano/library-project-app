import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'book_scanner.dart';

class BookCache {
  static const _dbName = 'shelfscan_cache.db';
  static const _table = 'book_results';
  static const _maxAgeDays = 30;

  Database? _db;

  Future<void> init() async {
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      join(dbPath, _dbName),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE $_table (
          cache_key    TEXT PRIMARY KEY,
          title        TEXT NOT NULL,
          author       TEXT NOT NULL,
          pub_year     TEXT,
          call_number  TEXT,
          confidence   TEXT NOT NULL,
          cached_at    INTEGER NOT NULL
        )
      '''),
    );
    debugPrint('[BookCache] opened at ${join(dbPath, _dbName)}');
  }

  // ──────────────────────────────────────────────────────────────
  // Key: sort + lowercase the noise-filtered words so minor OCR
  // variations across scans of the same book still hit the cache.
  // ──────────────────────────────────────────────────────────────
  String _key(List<String> texts) {
    final tokens = texts
        .map((t) => t.toLowerCase().trim())
        .where((t) => t.isNotEmpty)
        .toList()
      ..sort();
    return tokens.join('|');
  }

  Future<BookResult?> lookup(List<String> texts, int position) async {
    final db = _db;
    if (db == null) return null;

    final cutoff = DateTime.now()
        .subtract(const Duration(days: _maxAgeDays))
        .millisecondsSinceEpoch;

    try {
      final rows = await db.query(
        _table,
        where: 'cache_key = ? AND cached_at > ?',
        whereArgs: [_key(texts), cutoff],
        limit: 1,
      );
      if (rows.isEmpty) return null;

      final r = rows.first;
      debugPrint('[BookCache] hit: ${r['title']}');
      return BookResult(
        title: r['title'] as String,
        author: r['author'] as String,
        firstPublishYear: r['pub_year'] as String?,
        callNumber: r['call_number'] as String?,
        confidence: r['confidence'] as String,
        position: position,
        source: ResultSource.cache,
      );
    } catch (e) {
      debugPrint('[BookCache] lookup error: $e');
      return null;
    }
  }

  /// Wipe every cached result. Used during testing to avoid stale lookups.
  Future<void> clear() async {
    final db = _db;
    if (db == null) return;
    try {
      final n = await db.delete(_table);
      debugPrint('[BookCache] cleared $n rows');
    } catch (e) {
      debugPrint('[BookCache] clear error: $e');
    }
  }

  Future<void> store(List<String> texts, BookResult result) async {
    final db = _db;
    if (db == null) return;

    try {
      await db.insert(
        _table,
        {
          'cache_key': _key(texts),
          'title': result.title,
          'author': result.author,
          'pub_year': result.firstPublishYear,
          'call_number': result.callNumber,
          'confidence': result.confidence,
          'cached_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      debugPrint('[BookCache] stored: ${result.title}');
    } catch (e) {
      debugPrint('[BookCache] store error: $e');
    }
  }
}
