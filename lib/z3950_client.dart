// ─────────────────────────────────────────────────────────────────────────────
// Z39.50 client for Georgetown Public Library's public catalog.
//
// Biblionix (the library's ILS vendor) provided this access directly:
// z3950.biblionix.com:210, database "georgetown", no credentials. It's a
// standard, documented protocol (ANSI/NISO Z39.50) — not a scraper — and
// element set "C" additionally returns real-time circulation status, which
// isn't part of the base MARC record.
//
// This is not a general Z39.50 implementation. It builds exactly the PDU
// shapes this server accepts (byte-for-byte reverse-engineered from a real
// yaz-client session against the live server — see docs/z3950-notes.md)
// and only extracts the raw MARC21 record bytes from present responses,
// rather than fully decoding their BER (which Biblionix sends with
// indefinite lengths). dart:io's raw Socket is plain TCP — no ATS
// implications, since that's an HTTP(S)-only restriction.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'ber.dart';

/// Every step logs — on-device Z39.50 failures are otherwise invisible
/// (no server round-trip to see in a web inspector, no HTTP status code).
void _log(String msg) => debugPrint('[Z3950Client] $msg');

/// 1.2.840.10003.3.1 — the BIB-1 attribute set, used for every query here.
const _bib1Oid = [0x2a, 0x86, 0x48, 0xce, 0x13, 0x03, 0x01];

/// 1.2.840.10003.5.10 — MARC21/USMARC record syntax.
const _marc21Oid = [0x2a, 0x86, 0x48, 0xce, 0x13, 0x05, 0x0a];

/// BIB-1 use-attribute values (attributeType 1).
const _useIsbn = 7;
const _useTitle = 4;
const _useAuthor = 1003;

const _resultSetName = '1'; // the only result set we ever need live at once

class Z3950SearchException implements Exception {
  final String message;
  const Z3950SearchException(this.message);
  @override
  String toString() => 'Z3950SearchException: $message';
}

class Z3950Client {
  final String host;
  final int port;
  final String database;
  static const _timeout = Duration(seconds: 12);

  Socket? _socket;
  final _incoming = BytesBuilder();
  final _pending = <Completer<Uint8List>>[];
  StreamSubscription<Uint8List>? _sub;

  Z3950Client({
    this.host = 'z3950.biblionix.com',
    this.port = 210,
    this.database = 'georgetown',
  });

  Future<void> connect() async {
    _log('connecting to $host:$port/$database …');
    final Socket socket;
    try {
      socket = _socket = await Socket.connect(host, port, timeout: _timeout);
    } catch (e) {
      _log('connect FAILED: $e');
      rethrow;
    }
    _log('tcp connected (local ${socket.address.address}:${socket.port})');
    _sub = socket.listen(
      (chunk) {
        _log('recv ${chunk.length} bytes');
        _incoming.add(chunk);
        _deliverReadyPdus();
      },
      onError: (e) {
        _log('socket error: $e');
        _failAllPending('connection error: $e');
      },
      onDone: () {
        _log('socket closed by server');
        _failAllPending('connection closed');
      },
    );
    await _send(_buildInitRequest());
    final initResp = await _recv(); // nothing to negotiate, no auth
    _log('init ok (initResponse ${initResp.length} bytes)');
  }

  /// Returns the hit count. Does not retrieve any records.
  Future<int> searchIsbn(String isbn) async {
    _log('searchIsbn("$isbn")');
    await _send(_buildSearch(terms: [(_useIsbn, isbn)]));
    final hits = _parseResultCount(await _recv());
    _log('searchIsbn("$isbn") -> $hits hit(s)');
    return hits;
  }

  /// Returns the hit count for a title-AND-author keyword search. The
  /// server tokenizes multi-word terms itself, so the full strings are
  /// sent as-is — no need to split into words on our end.
  Future<int> searchTitleAuthor(String title, String author) async {
    _log('searchTitleAuthor("$title", "$author")');
    final terms = <(int, String)>[(_useTitle, title)];
    if (author.isNotEmpty) terms.add((_useAuthor, author));
    await _send(_buildSearch(terms: terms));
    final hits = _parseResultCount(await _recv());
    _log('searchTitleAuthor("$title", "$author") -> $hits hit(s)');
    return hits;
  }

  /// Up to [count] raw MARC21 (ISO 2709) records, in catalog relevance
  /// order, with real-time circulation status (element set "C").
  Future<List<Uint8List>> present(int count) async {
    if (count <= 0) return const [];
    _log('present($count)');
    await _send(_buildPresent(count));
    final records = _extractMarcRecords(await _recv(), count);
    _log('present($count) -> ${records.length} record(s)');
    return records;
  }

  Future<void> close() async {
    _log('closing');
    await _sub?.cancel();
    await _socket?.close();
    _socket = null;
  }

  // ── wire I/O ─────────────────────────────────────────────────────────────

  Future<void> _send(List<int> pdu) async {
    final socket = _socket;
    if (socket == null) {
      _log('send FAILED: not connected');
      throw const Z3950SearchException('not connected');
    }
    _log('send ${pdu.length} bytes');
    socket.add(pdu);
    await socket.flush();
  }

  /// Each call to [_send] is followed by exactly one [_recv] — Z39.50 here
  /// is strict request/response, so a simple FIFO queue of completers over
  /// the socket's byte stream is enough; no need for request IDs.
  Future<Uint8List> _recv() {
    final completer = Completer<Uint8List>();
    _pending.add(completer);
    _deliverReadyPdus();
    return completer.future.timeout(_timeout, onTimeout: () {
      _log('recv TIMED OUT after $_timeout waiting for server (${_incoming.length} '
          'byte(s) buffered, incomplete)');
      throw const Z3950SearchException('timed out waiting for server');
    });
  }

  void _deliverReadyPdus() {
    while (_pending.isNotEmpty) {
      final buf = _incoming.toBytes();
      int end;
      try {
        end = skipTlv(buf, 0);
      } catch (_) {
        return; // incomplete PDU so far — wait for more bytes
      }
      final pdu = Uint8List.sublistView(buf, 0, end);
      final rest = Uint8List.sublistView(buf, end);
      _incoming.clear();
      _incoming.add(rest);
      _pending.removeAt(0).complete(pdu);
    }
  }

  void _failAllPending(String reason) {
    for (final c in _pending) {
      if (!c.isCompleted) c.completeError(Z3950SearchException(reason));
    }
    _pending.clear();
  }

  // ── PDU construction ────────────────────────────────────────────────────

  List<int> _buildInitRequest() => ctx(20, [
        ...ctx(3, [0x00, 0xe0]), // protocolVersion: v1,v2,v3
        ...ctx(4, [0x00, 0xe9, 0xa2]), // options bitmap (search/present/etc.)
        ...ctx(5, [0x04, 0x00, 0x00, 0x00]), // preferredMessageSize
        ...ctx(6, [0x04, 0x00, 0x00, 0x00]), // exceptionalRecordSize
        ...ctx(110, utf8.encode('ShelfScan')), // implementationId
        ...ctx(111, utf8.encode('ShelfScan')), // implementationName
        ...ctx(112, utf8.encode('1.0')), // implementationVersion
      ], constructed: true);

  List<int> _buildSearch({required List<(int, String)> terms}) {
    final dbName = ctx(105, utf8.encode(database));
    final query = ctx(21, _buildRpnQuery(terms), constructed: true);
    return ctx(22, [
      ...ctx(13, berInt(0)), // smallSetUpperBound
      ...ctx(14, berInt(1)), // largeSetLowerBound
      ...ctx(15, berInt(0)), // mediumSetPresentNumber
      ...ctx(16, berInt(1)), // replaceIndicator
      ...ctx(17, utf8.encode(_resultSetName)),
      ...ctx(18, dbName, constructed: true), // databaseNames
      ...query,
    ], constructed: true);
  }

  /// One term → RPNQuery{ attributeSet, rpn: op[attrTerm] }.
  /// Two terms  → RPNQuery{ attributeSet, rpn: rpnRpnOp[term1, term2, AND] }.
  List<int> _buildRpnQuery(List<(int, String)> terms) {
    final attrSet = univ(6, _bib1Oid);
    final List<int> rpn;
    if (terms.length == 1) {
      rpn = ctx(0, _attrTerm(terms[0]), constructed: true);
    } else {
      final and = ctx(46, ctx(0, const []), constructed: true); // Operator::and
      rpn = ctx(
        1,
        [
          ...ctx(0, _attrTerm(terms[0]), constructed: true),
          ...ctx(0, _attrTerm(terms[1]), constructed: true),
          ...and,
        ],
        constructed: true,
      );
    }
    return ctx(1, [...attrSet, ...rpn], constructed: true);
  }

  /// AttributesPlusTerm: one AttributeElement (use=[attr.$1]) + the term
  /// string. The "SEQUENCE OF AttributeElement" wrapper always holds
  /// exactly one element here, so it's inlined rather than built generically.
  List<int> _attrTerm((int, String) attr) {
    final (useValue, term) = attr;
    final element = [...ctx(120, berInt(1)), ...ctx(121, berInt(useValue))];
    final attributes = ctx(44, univ(16, element, constructed: true), constructed: true);
    final termBytes = ctx(45, utf8.encode(term));
    return ctx(102, [...attributes, ...termBytes], constructed: true);
  }

  List<int> _buildPresent(int count) => ctx(24, [
        ...ctx(31, utf8.encode(_resultSetName)), // resultSetId
        ...ctx(30, berInt(1)), // resultSetStartPoint
        ...ctx(29, berInt(count)), // numberOfRecordsRequested
        ...ctx(19, ctx(0, utf8.encode('C')), constructed: true), // elementSetNames: generic "C"
        ...ctx(104, _marc21Oid), // preferredRecordSyntax
      ], constructed: true);

  // ── response parsing ────────────────────────────────────────────────────

  int _parseResultCount(Uint8List pdu) {
    // searchResponse ::= [23] SEQUENCE { resultCount [23], ... } — unlike
    // init/present responses this one is definite-length throughout.
    final headerLen = pdu[1] < 0x80 ? 2 : 2 + (pdu[1] & 0x7f);
    final fields = readFlatFields(pdu, headerLen, pdu.length);
    final status = fields[22];
    if (status != null && status.isNotEmpty && status[0] == 0) {
      throw const Z3950SearchException('search request failed');
    }
    final count = fields[23];
    if (count == null) return 0;
    var v = 0;
    for (final b in count) {
      v = (v << 8) | b;
    }
    return v;
  }

  /// Rather than fully decoding presentResponse's indefinite-length BER,
  /// this scans the (already frame-delimited) buffer for the MARC21
  /// record-syntax OID that precedes every record and reads the raw
  /// octet-string TLV that immediately follows it. Simple, and robust to
  /// however many NamePlusRecord wrappers surround each one.
  List<Uint8List> _extractMarcRecords(Uint8List buf, int maxCount) {
    final records = <Uint8List>[];
    var i = 0;
    while (records.length < maxCount) {
      final idx = _indexOf(buf, _oidMarker, i);
      if (idx == -1) break;
      var p = idx + _oidMarker.length;
      p++; // tag byte of the raw-record TLV (always primitive octet string)
      final lenByte = buf[p];
      p++;
      int len;
      if (lenByte < 0x80) {
        len = lenByte;
      } else {
        final n = lenByte & 0x7f;
        len = 0;
        for (var k = 0; k < n; k++) {
          len = (len << 8) | buf[p];
          p++;
        }
      }
      records.add(Uint8List.sublistView(buf, p, p + len));
      i = p + len;
    }
    return records;
  }

  static final _oidMarker = [0x06, 0x07, ..._marc21Oid];

  static int _indexOf(Uint8List haystack, List<int> needle, int from) {
    for (var i = from; i <= haystack.length - needle.length; i++) {
      var matched = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }
}
