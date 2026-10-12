// ─────────────────────────────────────────────────────────────────────────────
// Minimal BER (ASN.1 Basic Encoding Rules) helpers — just the handful of
// primitives Z39.50 needs: context-tagged/universal TLVs, BER length
// (short + long form), base-128 tag numbers above 30, and the one generic
// recursive "skip past one value" used to find PDU boundaries on the wire
// (handles both definite and indefinite length, since Biblionix's server
// emits indefinite-length responses).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:typed_data';

const _clsUniversal = 0;
const _clsContext = 2;

List<int> _tagBytes(int cls, bool constructed, int number) {
  final head = (cls << 6) | (constructed ? 0x20 : 0);
  if (number <= 30) return [head | number];
  // Base-128, most significant group first, continuation bit on all but
  // the last byte.
  final digits = <int>[number & 0x7f];
  var v = number >> 7;
  while (v > 0) {
    digits.add(v & 0x7f);
    v >>= 7;
  }
  final rev = digits.reversed.toList();
  for (var i = 0; i < rev.length - 1; i++) {
    rev[i] |= 0x80;
  }
  return [head | 0x1f, ...rev];
}

List<int> _berLen(int n) {
  if (n < 0x80) return [n];
  final bytes = <int>[];
  var v = n;
  while (v > 0) {
    bytes.insert(0, v & 0xff);
    v >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

/// A context-tagged (class 2) TLV — the overwhelming majority of Z39.50
/// fields. [constructed] is true when [content] holds nested TLVs rather
/// than a raw primitive value.
List<int> ctx(int number, List<int> content, {bool constructed = false}) => [
      ..._tagBytes(_clsContext, constructed, number),
      ..._berLen(content.length),
      ...content,
    ];

/// A universal-class TLV — only used for OBJECT IDENTIFIER (tag 6) and the
/// bare SEQUENCE (tag 16) that wraps a single AttributeElement.
List<int> univ(int number, List<int> content, {bool constructed = false}) => [
      ..._tagBytes(_clsUniversal, constructed, number),
      ..._berLen(content.length),
      ...content,
    ];

/// Minimal non-negative INTEGER encoding (0..65535 is all Z39.50 needs
/// here: use-attribute values, counts, result-set positions).
List<int> berInt(int value) {
  if (value <= 0x7f) return [value];
  if (value <= 0x7fff) return [(value >> 8) & 0xff, value & 0xff];
  return [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];
}

/// Advances past exactly one complete TLV starting at [i], returning the
/// offset just after it. Handles indefinite length (0x80 length byte,
/// terminated by a 00 00 end-of-contents marker) by recursing into
/// children until that marker is found — this is the only way to find
/// PDU boundaries on the wire, since Biblionix's server wraps several
/// response fields (initResponse, presentResponse) in indefinite length.
/// Throws RangeError if [b] doesn't yet contain the full value (the
/// caller uses that to mean "wait for more bytes").
int skipTlv(Uint8List b, int i) {
  final first = b[i];
  i++;
  if ((first & 0x1f) == 0x1f) {
    while ((b[i] & 0x80) != 0) {
      i++;
    }
    i++;
  }
  final lenByte = b[i];
  i++;
  if (lenByte == 0x80) {
    while (!(b[i] == 0x00 && b[i + 1] == 0x00)) {
      i = skipTlv(b, i);
    }
    return i + 2;
  }
  if (lenByte < 0x80) return i + lenByte;
  final n = lenByte & 0x7f;
  var len = 0;
  for (var k = 0; k < n; k++) {
    len = (len << 8) | b[i];
    i++;
  }
  return i + len;
}

/// Reads one level of definite-length, non-nested context-tagged fields
/// (used for SearchResponse, which — unlike the other responses — doesn't
/// use indefinite length). Returns tag number → raw content bytes.
Map<int, Uint8List> readFlatFields(Uint8List b, int start, int end) {
  final out = <int, Uint8List>{};
  var i = start;
  while (i < end) {
    final tagStart = i;
    final first = b[i];
    i++;
    var num = first & 0x1f;
    if (num == 0x1f) {
      num = 0;
      while (true) {
        num = (num << 7) | (b[i] & 0x7f);
        final more = b[i] & 0x80;
        i++;
        if (more == 0) break;
      }
    }
    final lenByte = b[i];
    i++;
    int len;
    if (lenByte == 0x80) {
      // Shouldn't happen at this level for our use case; bail safely.
      break;
    } else if (lenByte < 0x80) {
      len = lenByte;
    } else {
      final n = lenByte & 0x7f;
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | b[i];
        i++;
      }
    }
    out[num] = Uint8List.sublistView(b, i, i + len);
    i += len;
    assert(tagStart < i);
  }
  return out;
}
