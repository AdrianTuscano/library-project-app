import 'package:flutter/material.dart';
import 'book_scanner.dart';
import 'claude_ocr.dart' show NoBooksFoundException;
import 'design.dart';
import 'shelf_sort_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Sort helpers (used by ShelfSortScreen too, so kept here as package utilities)
// ─────────────────────────────────────────────────────────────────────────────

String lastName(String author) {
  final parts = author.trim().split(RegExp(r'\s+'));
  return parts.isEmpty ? '' : parts.last.toUpperCase();
}

double? deweyValue(String? callNumber) {
  if (callNumber == null) return null;
  final m = RegExp(r'^(\d{3}\.?\d*)').firstMatch(callNumber);
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

bool isNonFiction(BookResult b) => deweyValue(b.callNumber) != null;

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class BookResultsScreen extends StatefulWidget {
  final Future<ScanResult> resultsFuture;
  const BookResultsScreen({super.key, required this.resultsFuture});

  @override
  State<BookResultsScreen> createState() => _BookResultsScreenState();
}

class _BookResultsScreenState extends State<BookResultsScreen> {
  ScanResult? _result;
  String? _error;
  bool _noBooks = false;
  int _selected = 0;
  int _revealed = 0;

  // Fixed placeholder bars shown during processing animation
  static const _placeholders = [
    (w: 30.0, h: 152.0, c: Color(0xFF5C5348)),
    (w: 26.0, h: 170.0, c: Color(0xFF7D5411)),
    (w: 34.0, h: 160.0, c: Color(0xFF3F4A52)),
    (w: 28.0, h: 146.0, c: Color(0xFF8C3A2B)),
    (w: 40.0, h: 176.0, c: Color(0xFF2D2B2B)),
    (w: 32.0, h: 164.0, c: Color(0xFF6B6350)),
    (w: 29.0, h: 154.0, c: Color(0xFF9B7232)),
    (w: 27.0, h: 168.0, c: Color(0xFF4A4740)),
    (w: 31.0, h: 150.0, c: Color(0xFF7A6A55)),
    (w: 36.0, h: 172.0, c: Color(0xFF605D5D)),
  ];

  @override
  void initState() {
    super.initState();
    _startLoading();
  }

  void _startLoading() {
    // Reveal placeholder bars one by one
    Future.microtask(() async {
      for (var i = 1; i <= _placeholders.length; i++) {
        await Future.delayed(const Duration(milliseconds: 160));
        if (!mounted) return;
        setState(() => _revealed = i);
      }
    });

    widget.resultsFuture.then((result) {
      if (!mounted) return;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() => _result = result);
      });
    }).catchError((Object e) {
      if (!mounted) return;
      if (e is NoBooksFoundException) {
        setState(() => _noBooks = true);
      } else {
        setState(() => _error = e.toString());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_noBooks) return _buildNoBooks();
    if (_error != null) return _buildError();
    if (_result == null) return _buildProcessing();
    return _buildShelf(_result!.books);
  }

  // ── Processing ──────────────────────────────────────────────────────────────

  Widget _buildProcessing() {
    final rev = _revealed;
    final total = _placeholders.length;
    final matching = rev >= total;

    return Scaffold(
      backgroundColor: kBgDark,
      body: SafeArea(
        child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 180,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < total; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 6),
                      width: _placeholders[i].w,
                      height: _placeholders[i].h,
                      color: i < rev
                          ? _placeholders[i].c
                          : const Color(0xFF26241F),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              matching ? 'Identifying books' : 'Reading spines',
              style: kHeading(24, color: const Color(0xFFEFE9E0)),
            ),
            const SizedBox(height: 6),
            Text(
              matching ? 'Matching titles and authors…' : 'Scanning your shelf…',
              style: kLabel(12, color: const Color(0xFF8D857A)),
            ),
          ],
        ),
      ),
      ),
    );
  }

  // ── No books in frame ───────────────────────────────────────────────────────

  Widget _buildNoBooks() {
    return Scaffold(
      backgroundColor: kBgDark,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 180,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < _placeholders.length; i++)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        width: _placeholders[i].w,
                        height: _placeholders[i].h,
                        color: const Color(0xFF26241F),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Text('No books detected',
                  style: kHeading(24, color: const Color(0xFFEFE9E0))),
              const SizedBox(height: 8),
              Text(
                'Make sure book spines fill the frame\nand the shelf is well-lit.',
                textAlign: TextAlign.center,
                style: kLabel(13, color: const Color(0xFF8D857A)),
              ),
              const SizedBox(height: 28),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
                  decoration: BoxDecoration(
                    border: Border.all(color: kGold),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text('Scan again', style: kLabel(13, color: kGoldText)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Shelf ───────────────────────────────────────────────────────────────────

  Widget _buildShelf(List<BookResult> books) {
    if (books.isEmpty) {
      return Scaffold(
        backgroundColor: kBgScreen,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('No books found', style: kHeading(24)),
              const SizedBox(height: 10),
              Text('Try scanning again with better lighting',
                  style: kBody(14, color: kTextMut)),
              const SizedBox(height: 24),
              _GoldOutlineButton(
                  label: 'Back', onTap: () => Navigator.pop(context)),
            ],
          ),
        ),
      );
    }

    final sel = books[_selected.clamp(0, books.length - 1)];

    return Scaffold(
      backgroundColor: kBgScreen,
      body: SafeArea(
        child: Column(
        children: [
          _buildNavBar(books),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildSpineArea(books)),
                Container(
                  width: 292,
                  decoration: const BoxDecoration(
                    color: kBgPanel,
                    border: Border(left: BorderSide(color: kDivider)),
                  ),
                  child: _buildDetailPanel(sel),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildNavBar(List<BookResult> books) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: kBgScreen,
        border: Border(bottom: BorderSide(color: kDivider)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Text('←', style: kBody(16, color: kTextMut)),
            ),
          ),
          Text('Scanned shelf', style: kHeading(19)),
          const Spacer(),
          Text('${books.length} spines recognised',
              style: kLabel(11, color: kTextFaint)),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ShelfSortScreen(books: books),
              ),
            ),
            child: Container(
              margin: const EdgeInsets.only(right: 18),
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                border: Border.all(color: kGold),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('Check sorting',
                  style: kLabel(12, color: kGoldText)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpineArea(List<BookResult> books) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 0, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < books.length; i++)
                    _SpineBar(
                      book: books[i],
                      selected: i == _selected,
                      onTap: () => setState(() => _selected = i),
                    ),
                  const SizedBox(width: 20),
                ],
              ),
            ),
          ),
        ),
        // Shelf line
        Container(
          height: 6,
          margin: const EdgeInsets.only(right: 0),
          color: const Color(0xFFD7D3CF),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 7, 20, 10),
          child: Text('Tap a spine to see the full record.',
              style: kBody(11, color: kTextFaint, style: FontStyle.italic)),
        ),
      ],
    );
  }

  Widget _buildDetailPanel(BookResult b) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'POSITION ${b.position}',
            style: kLabel(10, color: kTextFaint, tracking: 0.16),
          ),
          const SizedBox(height: 9),
          Text(b.title, style: kHeading(25)),
          const SizedBox(height: 13),
          const Divider(color: kDivider, height: 1),
          const SizedBox(height: 13),
          _DetailField(label: 'AUTHOR', value: b.author),
          if (b.callNumber != null) ...[
            const SizedBox(height: 9),
            _DetailField(label: 'CALL NUMBER', value: b.callNumber!),
          ],
          if (b.firstPublishYear != null) ...[
            const SizedBox(height: 9),
            _DetailField(label: 'PUBLISHED', value: b.firstPublishYear!),
          ],
          const SizedBox(height: 9),
          _DetailField(
              label: 'MATCH',
              value: b.confidence == 'high' ? 'High confidence' : 'Possible match'),
          const Spacer(),
          GestureDetector(
            onTap: () {},
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                border: Border.all(color: kDivider),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('Edit record',
                  textAlign: TextAlign.center,
                  style: kLabel(13, color: kTextMut)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Scaffold(
      backgroundColor: kBgScreen,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Scan error', style: kHeading(24)),
            const SizedBox(height: 8),
            Text(_error!, style: kBody(13, color: kTextMut)),
            const SizedBox(height: 24),
            _GoldOutlineButton(label: 'Back', onTap: () => Navigator.pop(context)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spine bar — a single book spine in the shelf visualization
// ─────────────────────────────────────────────────────────────────────────────

class _SpineBar extends StatelessWidget {
  final BookResult book;
  final bool selected;
  final VoidCallback onTap;

  const _SpineBar({
    required this.book,
    required this.selected,
    required this.onTap,
  });

  int get _w => spineWidth(book.title);
  int get _h => spineHeight(book.title, book.author);

  @override
  Widget build(BuildContext context) {
    final color = spineColor(book.position);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: _w.toDouble(),
        height: _h.toDouble(),
        margin: const EdgeInsets.only(right: 7),
        decoration: BoxDecoration(
          color: color,
          border: selected
              ? Border.all(color: kGold, width: 1.5)
              : null,
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: RotatedBox(
            quarterTurns: 3,
            child: Text(
              '${book.position}  ${book.title}',
              style: kLabel(10, color: const Color(0xFFF1ECE4), tracking: 0.05),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared UI fragments
// ─────────────────────────────────────────────────────────────────────────────

class _DetailField extends StatelessWidget {
  final String label;
  final String value;
  const _DetailField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: kLabel(10, color: kTextFaint, tracking: 0.14)),
        const SizedBox(height: 2),
        Text(value, style: kBody(13.5)),
      ],
    );
  }
}

class _GoldOutlineButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _GoldOutlineButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: kGold),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label, style: kLabel(13, color: kGoldText)),
      ),
    );
  }
}
