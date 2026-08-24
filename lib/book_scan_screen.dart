import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'design.dart';
import 'library_status_service.dart';

class BookScanScreen extends StatefulWidget {
  final String isbn;
  const BookScanScreen({super.key, required this.isbn});

  @override
  State<BookScanScreen> createState() => _BookScanScreenState();
}

class _BookScanScreenState extends State<BookScanScreen> {
  _BookInfo? _info;
  LibraryStatus? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _fetchBookInfo(widget.isbn),
        libraryStatus.checkByIsbn(widget.isbn),
      ]);
      if (!mounted) return;
      setState(() {
        _info = results[0] as _BookInfo?;
        _status = results[1] as LibraryStatus;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgDark,
      body: SafeArea(
        child: _error != null ? _buildError() : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final loading = _info == null || _status == null;
    return Column(
      children: [
        _NavBar(
          onBack: () => Navigator.pop(context),
          title: loading ? 'Looking up…' : (_info?.title ?? 'Unknown title'),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator(color: kGold))
              : _buildResult(),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final info = _info;
    final status = _status!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusBanner(status: status),
          const SizedBox(height: 24),
          if (info != null) ...[
            Text(info.title,
                style: kHeading(26, color: const Color(0xFFEFE9E0))),
            const SizedBox(height: 6),
            Text(info.author,
                style: kLabel(14, color: const Color(0xFFB0A898))),
            const SizedBox(height: 20),
            const Divider(color: Color(0xFF2A2927)),
            const SizedBox(height: 16),
            _Field(label: 'ISBN', value: widget.isbn),
            if (info.publisher != null) ...[
              const SizedBox(height: 10),
              _Field(label: 'PUBLISHER', value: info.publisher!),
            ],
            if (info.publishYear != null) ...[
              const SizedBox(height: 10),
              _Field(label: 'PUBLISHED', value: info.publishYear!),
            ],
            if (status.callNumber != null) ...[
              const SizedBox(height: 10),
              _Field(label: 'CALL NUMBER', value: status.callNumber!),
            ],
          ] else ...[
            // No Open Library record for this ISBN.
            Text('ISBN: ${widget.isbn}',
                style: kLabel(13, color: const Color(0xFF8D857A))),
            const SizedBox(height: 8),
            Text('No record found in Open Library',
                style: kBody(13, color: const Color(0xFF605D5D))),
            if (status.callNumber != null) ...[
              const SizedBox(height: 10),
              _Field(label: 'CALL NUMBER', value: status.callNumber!),
            ],
          ],
          const SizedBox(height: 32),
          if (status.isReshelved)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(color: kRust.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(4),
                color: kRust.withValues(alpha: 0.08),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: kRust, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This copy is marked checked out'
                      '${status.dueDate != null ? ' until ${status.dueDate}' : ''}'
                      ' but is physically on the shelf.\n'
                      'It may have been reshelved without being returned.',
                      style: kBody(12.5, color: const Color(0xFFD4887A)),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                border: Border.all(color: kGold),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('Scan another book',
                  textAlign: TextAlign.center,
                  style: kLabel(13, color: kGoldText)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Lookup failed', style: kHeading(22, color: const Color(0xFFEFE9E0))),
          const SizedBox(height: 8),
          Text(_error!, style: kBody(13, color: const Color(0xFF8D857A)),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              decoration: BoxDecoration(
                  border: Border.all(color: kGold),
                  borderRadius: BorderRadius.circular(3)),
              child: Text('Back', style: kLabel(13, color: kGoldText)),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookInfo {
  final String title;
  final String author;
  final String? publisher;
  final String? publishYear;

  const _BookInfo({
    required this.title,
    required this.author,
    this.publisher,
    this.publishYear,
  });
}

Future<_BookInfo?> _fetchBookInfo(String isbn) async {
  try {
    final uri = Uri.parse(
        'https://openlibrary.org/api/books?bibkeys=ISBN:$isbn&format=json&jscmd=data');
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final book = data['ISBN:$isbn'] as Map<String, dynamic>?;
    if (book == null) return null;

    final title = book['title'] as String? ?? 'Unknown title';
    final authorsList = book['authors'] as List?;
    final author = (authorsList?.first as Map?)?['name'] as String? ?? '';
    final publishersList = book['publishers'] as List?;
    final publisher = (publishersList?.first as Map?)?['name'] as String?;
    final publishYear = book['publish_date'] as String?;

    return _BookInfo(
      title: title,
      author: author,
      publisher: publisher,
      publishYear: publishYear,
    );
  } catch (_) {
    return null;
  }
}

class _NavBar extends StatelessWidget {
  final VoidCallback onBack;
  final String title;
  const _NavBar({required this.onBack, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1917),
        border: Border(bottom: BorderSide(color: Color(0xFF2A2927))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Text('←', style: kBody(16, color: const Color(0xFF8D857A))),
            ),
          ),
          Expanded(
            child: Text(title,
                style: kHeading(17, color: const Color(0xFFEFE9E0)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Text('Book scan',
                style: kLabel(11, color: const Color(0xFF605D5D))),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final LibraryStatus status;
  const _StatusBanner({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, sub, color) = switch (status.status) {
      CircStatus.available => (
          'Available',
          'This copy is on the shelf and can be borrowed',
          const Color(0xFF4A7C59),
        ),
      CircStatus.checkedOut => (
          'Checked out',
          status.dueDate != null ? 'Due back ${status.dueDate}' : 'Currently borrowed',
          kRust,
        ),
      CircStatus.unknown => (
          'Status unknown',
          'Could not retrieve circulation record',
          const Color(0xFF605D5D),
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: kLabel(13, color: color, tracking: 0.08)),
              const SizedBox(height: 2),
              Text(sub, style: kBody(12, color: const Color(0xFF8D857A))),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  const _Field({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: kLabel(10, color: const Color(0xFF605D5D), tracking: 0.14)),
        const SizedBox(height: 2),
        Text(value, style: kBody(13.5, color: const Color(0xFFD4CDBF))),
      ],
    );
  }
}
