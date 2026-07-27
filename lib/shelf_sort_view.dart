import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'book_scanner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ShelfSortView — visual "where each book goes to get sorted"
//
// Top row  = the shelf as scanned (left → right = physical order).
// Bottom row = the same books in the target sorted order.
// Connectors link each book from its current slot to its destination slot.
// Each book keeps ONE colour across both rows so it's traceable by eye.
// Tapping a spine opens its details.
// ─────────────────────────────────────────────────────────────────────────────

const _cardBg = Color(0xFF1C1F28);
const _cardBorder = Color(0xFF272B36);
const _textSecondary = Color(0xFF9BA0AB);
const _textTertiary = Color(0xFF5C6270);
const _accentGreen = Color(0xFF30D158);
const _accentRed = Color(0xFFFF453A);

// Distinct, readable spine colours; assigned by scan position so a book looks
// the same in both rows.
const _spinePalette = <Color>[
  Color(0xFF4E9BFF), Color(0xFFFF9F0A), Color(0xFF30D158), Color(0xFFBF5AF2),
  Color(0xFFFF6482), Color(0xFF64D2FF), Color(0xFFFFD60A), Color(0xFF5E5CE6),
  Color(0xFFFF7A45), Color(0xFF2CC0A0),
];
Color _spineColor(int position) => _spinePalette[(position - 1) % _spinePalette.length];

// Spine + layout geometry.
const double _spineW = 48;
const double _spineH = 128;
const double _gap = 14;
const double _rowLabelH = 26;
const double _arrowGap = 76; // vertical space between the two rows for connectors
const double _sidePad = 20;

class ShelfSortView extends StatelessWidget {
  /// Books in physical (scan) order — position 1..n, left → right.
  final List<BookResult> currentOrder;

  /// The same books in the chosen sorted order.
  final List<BookResult> sortedOrder;

  /// e.g. "author" / "call number" — shown on the lower row label.
  final String targetLabel;

  const ShelfSortView({
    super.key,
    required this.currentOrder,
    required this.sortedOrder,
    required this.targetLabel,
  });

  @override
  Widget build(BuildContext context) {
    final n = currentOrder.length;
    if (n == 0) return const SizedBox.shrink();

    final returns = currentOrder
        .where((b) => b.availability == LibraryAvailability.checkedOut)
        .toList();

    // Destination slot for each current index, matched by unique position.
    final targetIndexByPos = <int, int>{
      for (var j = 0; j < sortedOrder.length; j++) sortedOrder[j].position: j,
    };

    final contentW = _sidePad * 2 + n * _spineW + (n - 1) * _gap;
    final topRowTop = _rowLabelH;
    final bottomRowTop = topRowTop + _spineH + _arrowGap;
    final contentH = bottomRowTop + _spineH + _rowLabelH;

    double centerX(int index) =>
        _sidePad + index * (_spineW + _gap) + _spineW / 2;

    // Build connector links (current slot bottom → target slot top).
    final links = <_Link>[];
    for (var i = 0; i < n; i++) {
      final book = currentOrder[i];
      final j = targetIndexByPos[book.position] ?? i;
      final isReturn = book.availability == LibraryAvailability.checkedOut;
      links.add(_Link(
        x1: centerX(i),
        y1: topRowTop + _spineH,
        x2: centerX(j),
        y2: bottomRowTop,
        color: isReturn ? _accentRed : _spineColor(book.position),
        inPlace: i == j && !isReturn,
      ));
    }

    final diagram = SizedBox(
      width: math.max(contentW, MediaQuery.of(context).size.width),
      height: contentH,
      child: Stack(
        children: [
          // Connector layer (behind the spines).
          Positioned.fill(
            child: CustomPaint(painter: _ConnectorPainter(links)),
          ),

          // Row labels.
          Positioned(
            top: 0,
            left: _sidePad,
            child: _RowLabel('ON THE SHELF NOW'),
          ),
          Positioned(
            top: bottomRowTop + _spineH + 4,
            left: _sidePad,
            child: _RowLabel('SORTED BY ${targetLabel.toUpperCase()}'),
          ),

          // Top row — current order.
          for (var i = 0; i < n; i++)
            Positioned(
              top: topRowTop,
              left: centerX(i) - _spineW / 2,
              child: _Spine(
                book: currentOrder[i],
                color: _spineColor(currentOrder[i].position),
              ),
            ),

          // Bottom row — sorted order.
          for (var j = 0; j < n; j++)
            Positioned(
              top: bottomRowTop,
              left: centerX(j) - _spineW / 2,
              child: _Spine(
                book: sortedOrder[j],
                color: _spineColor(sortedOrder[j].position),
              ),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (returns.isNotEmpty) _ReturnBanner(books: returns),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: diagram,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            'Tap a spine for details · green line = already in place · red = Book Return',
            style: TextStyle(color: _textTertiary, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

// Red warning: these books are checked out in the ILS — they were reshelved by
// mistake and must go to the Book Return, not be sorted onto the shelf.
class _ReturnBanner extends StatelessWidget {
  final List<BookResult> books;
  const _ReturnBanner({required this.books});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _accentRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _accentRed.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: _accentRed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${books.length} book${books.length == 1 ? "" : "s"} to the Book Return — do NOT shelve',
                  style: const TextStyle(
                      color: _accentRed,
                      fontSize: 13,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Still checked out in the catalog — send to the return bin to be checked in and re-scanned.',
            style: TextStyle(
                color: _accentRed.withValues(alpha: 0.9), fontSize: 11),
          ),
          const SizedBox(height: 8),
          ...books.map((b) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('#${b.position}  ${b.title}',
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              )),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spine
// ─────────────────────────────────────────────────────────────────────────────

class _Spine extends StatelessWidget {
  final BookResult book;
  final Color color;
  const _Spine({required this.book, required this.color});

  @override
  Widget build(BuildContext context) {
    // Checked-out books override the palette colour with a red "return" state.
    final isReturn = book.availability == LibraryAvailability.checkedOut;
    final spineColor = isReturn ? _accentRed : color;

    return GestureDetector(
      onTap: () => _showDetails(context, book),
      child: Container(
        width: _spineW,
        height: _spineH,
        decoration: BoxDecoration(
          color: spineColor.withValues(alpha: isReturn ? 0.28 : 0.18),
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: spineColor, width: 4)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Column(
          children: [
            // Position badge, or a return icon when checked out.
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: spineColor, shape: BoxShape.circle),
              child: isReturn
                  ? const Icon(Icons.assignment_return, size: 11, color: Colors.white)
                  : Text('${book.position}',
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 4),
            // Vertical title, like a real spine.
            Expanded(
              child: RotatedBox(
                quarterTurns: 1,
                child: Center(
                  child: Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showDetails(BuildContext context, BookResult book) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: _cardBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: _cardBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(book.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          if (book.author.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(book.author,
                style: const TextStyle(color: _textSecondary, fontSize: 14)),
          ],
          const SizedBox(height: 12),
          if (book.availability == LibraryAvailability.checkedOut) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _accentRed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _accentRed.withValues(alpha: 0.45)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.assignment_return, size: 16, color: _accentRed),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Checked out — send to Book Return, don\'t shelve',
                      style: TextStyle(
                          color: _accentRed,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip('Shelf position ${book.position}'),
              if (book.firstPublishYear != null) _chip(book.firstPublishYear!),
              if (book.callNumber != null) _chip(book.callNumber!),
              _chip(book.confidence == 'high' ? 'High match' : 'Possible match'),
            ],
          ),
        ],
      ),
    ),
  );
}

Widget _chip(String label) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Text(label,
          style: const TextStyle(color: _textSecondary, fontSize: 12)),
    );

class _RowLabel extends StatelessWidget {
  final String text;
  const _RowLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: _textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Connector painter
// ─────────────────────────────────────────────────────────────────────────────

class _Link {
  final double x1, y1, x2, y2;
  final Color color;
  final bool inPlace;
  const _Link({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.color,
    required this.inPlace,
  });
}

class _ConnectorPainter extends CustomPainter {
  final List<_Link> links;
  _ConnectorPainter(this.links);

  @override
  void paint(Canvas canvas, Size size) {
    for (final link in links) {
      final color = link.inPlace ? _accentGreen : link.color;
      final paint = Paint()
        ..color = color.withValues(alpha: link.inPlace ? 0.55 : 0.85)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      // Smooth S-curve between the two slots.
      final start = Offset(link.x1, link.y1);
      final end = Offset(link.x2, link.y2);
      final midY = (link.y1 + link.y2) / 2;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(start.dx, midY, end.dx, midY, end.dx, end.dy);
      canvas.drawPath(path, paint);

      // Arrowhead at the destination, pointing down.
      const barb = 9.0;
      final fill = Paint()
        ..color = color.withValues(alpha: link.inPlace ? 0.55 : 0.9)
        ..style = PaintingStyle.fill;
      final head = Path()
        ..moveTo(end.dx, end.dy + 2)
        ..lineTo(end.dx - barb * 0.6, end.dy - barb)
        ..lineTo(end.dx + barb * 0.6, end.dy - barb)
        ..close();
      canvas.drawPath(head, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectorPainter old) => old.links != links;
}
