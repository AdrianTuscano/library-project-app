// ─────────────────────────────────────────────────────────────────────────────
// Minimal MARC21 (ISO 2709) record parser — just enough to read the fields
// the app needs: 020 (ISBN), 100/700 (author), 245 (title), and 852
// (holdings — location, call number, and, from Georgetown's Z39.50 server
// with element set "C", real-time status in subfield $1: "In" or "Out").
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:typed_data';

const _fieldTerminator = 0x1e;
const _subfieldDelimiter = 0x1f;

class MarcField {
  final String tag;
  final Map<String, List<String>> _subfields;

  const MarcField(this.tag, this._subfields);

  /// First value of subfield [code], if present.
  String? sub(String code) {
    final values = _subfields[code];
    return values == null || values.isEmpty ? null : values.first;
  }

  List<String> subAll(String code) => _subfields[code] ?? const [];

  static MarcField _controlField(String tag, List<int> bytes) =>
      MarcField(tag, {'_': [utf8.decode(bytes, allowMalformed: true)]});

  static MarcField _dataField(String tag, List<int> bytes) {
    final subs = <String, List<String>>{};
    var i = bytes.length >= 2 ? 2 : 0; // skip the two indicator bytes
    while (i < bytes.length) {
      if (bytes[i] != _subfieldDelimiter || i + 1 >= bytes.length) {
        i++;
        continue;
      }
      final code = String.fromCharCode(bytes[i + 1]);
      i += 2;
      final start = i;
      while (i < bytes.length && bytes[i] != _subfieldDelimiter && bytes[i] != _fieldTerminator) {
        i++;
      }
      final value = utf8.decode(bytes.sublist(start, i), allowMalformed: true).trim();
      subs.putIfAbsent(code, () => []).add(value);
    }
    return MarcField(tag, subs);
  }
}

class MarcRecord {
  final List<MarcField> fields;
  const MarcRecord(this.fields);

  /// All fields with the given tag (e.g. '852' — usually one per physical
  /// copy, but a record can hold several).
  List<MarcField> operator [](String tag) => fields.where((f) => f.tag == tag).toList();

  static MarcRecord parse(Uint8List bytes) {
    // Leader: 24 ASCII digits/codes. Bytes 12–16 give the base address of
    // data (where the directory ends and field content begins).
    final leader = String.fromCharCodes(bytes.sublist(0, 24));
    final baseAddress = int.tryParse(leader.substring(12, 17)) ?? 24;

    final fields = <MarcField>[];
    var i = 24;
    // Directory: repeating 12-byte entries (tag[3] + length[4] + start[5]),
    // terminated by the field terminator just before baseAddress.
    while (i + 12 <= baseAddress - 1) {
      final tag = String.fromCharCodes(bytes.sublist(i, i + 3));
      final len = int.tryParse(String.fromCharCodes(bytes.sublist(i + 3, i + 7))) ?? 0;
      final start = int.tryParse(String.fromCharCodes(bytes.sublist(i + 7, i + 12))) ?? 0;
      i += 12;

      final fieldStart = baseAddress + start;
      final fieldEnd = (fieldStart + len).clamp(0, bytes.length);
      if (fieldStart >= bytes.length || fieldEnd <= fieldStart) continue;
      var content = bytes.sublist(fieldStart, fieldEnd);
      if (content.isNotEmpty && content.last == _fieldTerminator) {
        content = content.sublist(0, content.length - 1);
      }

      fields.add(tag.startsWith('00')
          ? MarcField._controlField(tag, content)
          : MarcField._dataField(tag, content));
    }
    return MarcRecord(fields);
  }
}
