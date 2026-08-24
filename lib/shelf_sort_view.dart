import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'book_results_screen.dart' show lastName, isNonFiction, deweyValue;
import 'book_scanner.dart';
import 'design.dart';

class _SortItem {
  final BookResult book;
  final int currentSlot;
  final int? targetSlot; // null = non-fiction, pull aside

  const _SortItem(this.book, this.currentSlot, this.targetSlot);

  bool get isNF => targetSlot == null;
  bool get inPlace => targetSlot == currentSlot;
  bool get needsFix => isNF || !inPlace;
}

String _sortKey(BookResult b) {
  final cn = b.callNumber?.trim().toUpperCase();
  if (cn != null && cn.isNotEmpty) {
    final fictionMatch = RegExp(r'^J?F\s+(.+)$').firstMatch(cn);
    if (fictionMatch != null) return fictionMatch.group(1)!;

    final bioMatch = RegExp(r'^BIO?\s+(.+)$').firstMatch(cn);
    if (bioMatch != null) return bioMatch.group(1)!;

    final dewey = deweyValue(b.callNumber);
    if (dewey != null) return dewey.toStringAsFixed(4).padLeft(12, '0');

    return cn;
  }
  return lastName(b.author);
}

bool _isNonFiction(BookResult b) {
  final cn = b.callNumber?.trim().toUpperCase();
  if (cn != null && cn.isNotEmpty) {
    if (RegExp(r'^J?F\b').hasMatch(cn)) return false;
    return true;
  }
  return isNonFiction(b);
}

List<_SortItem> _computeSort(List<BookResult> books) {
  final fiction = books.where((b) => !_isNonFiction(b)).toList()
    ..sort((a, b) => _sortKey(a).compareTo(_sortKey(b)));

  final Map<int, int> targetByPos = {};
  for (var i = 0; i < fiction.length; i++) {
    targetByPos[fiction[i].position] = i + 1;
  }

  return List.generate(books.length, (i) {
    final b = books[i];
    return _SortItem(b, i + 1, _isNonFiction(b) ? null : targetByPos[b.position]);
  });
}

int _spineW(BookResult b) => spineWidth(b.title);
int _spineH(BookResult b) => spineHeight(b.title, b.author);

class ShelfSortScreen extends StatefulWidget {
  final List<BookResult> books;
  const ShelfSortScreen({super.key, required this.books});

  @override
  State<ShelfSortScreen> createState() => _ShelfSortScreenState();
}

class _ShelfSortScreenState extends State<ShelfSortScreen> {
  late final List<_SortItem> _items;

  @override
  void initState() {
    super.initState();
    _items = _computeSort(widget.books);
  }

  @override
  Widget build(BuildContext context) {
    final fixes = _items.where((it) => it.needsFix).toList();

    return Scaffold(
      backgroundColor: kBgScreen,
      body: SafeArea(
        child: Column(
          children: [
            _buildNavBar(fixes.length),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildVisualization()),
                  Container(
                    width: 292,
                    decoration: const BoxDecoration(
                      color: kBgPanel,
                      border: Border(left: BorderSide(color: kDivider)),
                    ),
                    child: _buildActionPanel(fixes),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavBar(int fixCount) {
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
          Text('Sorting check', style: kHeading(19)),
          const SizedBox(width: 14),
          Text('Author surname A–Z · Dewey for non-fiction',
              style: kLabel(11, color: kTextFaint)),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Text(
              '$fixCount of ${widget.books.length} out of place',
              style: kLabel(11, color: fixCount > 0 ? kRust : const Color(0xFF3A6B3A)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVisualization() {
    if (_items.isEmpty) return const SizedBox.shrink();

    final widths = _items.map((it) => _spineW(it.book).toDouble()).toList();
    const gap = 7.0;
    const arcZoneH = 88.0;
    const badgeH = 22.0;
    final maxSpineH = _items.map((it) => _spineH(it.book).toDouble()).fold(0.0, math.max);
    const shelfLineH = 6.0;
    const bottomPad = 10.0;

    final totalH = arcZoneH + badgeH + maxSpineH + shelfLineH + bottomPad;

    final xs = <double>[];
    double cx = 0;
    for (final w in widths) {
      xs.add(cx);
      cx += w + gap;
    }
    final totalW = cx - gap + 20;

    double centerX(int i) => xs[i] + widths[i] / 2;
    double spineTopY(int i) => arcZoneH + badgeH + (maxSpineH - _spineH(_items[i].book));

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: 20),
          child: SizedBox(
            width: math.max(totalW, constraints.maxWidth - 20),
            height: totalH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ArcPainter(
                      items: _items,
                      centerXs: List.generate(_items.length, centerX),
                      spineTopYs: List.generate(_items.length, spineTopY),
                    ),
                  ),
                ),
                for (var i = 0; i < _items.length; i++)
                  if (_items[i].needsFix)
                    Positioned(
                      top: arcZoneH,
                      left: xs[i],
                      width: widths[i],
                      child: _Badge(item: _items[i]),
                    ),
                for (var i = 0; i < _items.length; i++)
                  Positioned(
                    top: spineTopY(i),
                    left: xs[i],
                    child: _SortSpine(item: _items[i]),
                  ),
                Positioned(
                  top: arcZoneH + badgeH + maxSpineH,
                  left: 0,
                  width: math.max(totalW, constraints.maxWidth),
                  child: Container(height: shelfLineH, color: const Color(0xFFD7D3CF)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionPanel(List<_SortItem> fixes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Text('TO FIX', style: kLabel(10, tracking: 0.18)),
        ),
        const Divider(color: kDivider, height: 1),
        Expanded(
          child: fixes.isEmpty
              ? Center(
                  child: Text('All in order',
                      style: kBody(13, color: kTextFaint, style: FontStyle.italic)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: fixes.length,
                  separatorBuilder: (_, __) => const Divider(color: kDivider, height: 1),
                  itemBuilder: (_, i) => _ActionItem(item: fixes[i]),
                ),
        ),
        const Divider(color: kDivider, height: 1),
        Padding(
          padding: const EdgeInsets.all(14),
          child: GestureDetector(
            onTap: () => Navigator.popUntil(context, (r) => r.isFirst),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                border: Border.all(color: kGold),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('Rescan shelf',
                  textAlign: TextAlign.center,
                  style: kLabel(13, color: kGoldText)),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArcPainter extends CustomPainter {
  final List<_SortItem> items;
  final List<double> centerXs;
  final List<double> spineTopYs;

  const _ArcPainter({
    required this.items,
    required this.centerXs,
    required this.spineTopYs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (!item.needsFix) continue;

      final x1 = centerXs[i];
      final y1 = spineTopYs[i];

      if (item.isNF) {
        _drawSectionArrow(canvas, x1, y1);
      } else {
        final j = item.targetSlot! - 1;
        if (j < 0 || j >= centerXs.length) continue;
        _drawArc(canvas, x1, y1, centerXs[j], spineTopYs[j]);
      }
    }
  }

  void _drawSectionArrow(Canvas canvas, double cx, double spineTop) {
    final strokePaint = Paint()
      ..color = kRust
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(cx, spineTop), Offset(cx, spineTop - 56), strokePaint);

    final fillPaint = Paint()..color = kRust..style = PaintingStyle.fill;
    final arrowHead = Path()
      ..moveTo(cx, spineTop - 61)
      ..lineTo(cx - 5, spineTop - 50)
      ..lineTo(cx + 5, spineTop - 50)
      ..close();
    canvas.drawPath(arrowHead, fillPaint);
  }

  void _drawArc(Canvas canvas, double x1, double y1, double x2, double y2) {
    final paint = Paint()
      ..color = kGold
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final dist = (x2 - x1).abs();
    final lift = math.min(40 + dist * 0.09, 78.0);

    canvas.drawPath(
      Path()
        ..moveTo(x1, y1)
        ..cubicTo(x1, y1 - lift, x2, y2 - lift, x2, y2),
      paint,
    );

    final fillPaint = Paint()..color = kGold..style = PaintingStyle.fill;
    final arrowHead = Path()
      ..moveTo(x2, y2 + 5)
      ..lineTo(x2 - 5, y2 - 6)
      ..lineTo(x2 + 5, y2 - 6)
      ..close();
    canvas.drawPath(arrowHead, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.items != items || old.centerXs != centerXs || old.spineTopYs != spineTopYs;
}

class _SortSpine extends StatelessWidget {
  final _SortItem item;
  const _SortSpine({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = spineColor(item.book.position);
    final borderColor = item.isNF ? kRust : (item.inPlace ? null : kGold);

    return Container(
      width: _spineW(item.book).toDouble(),
      height: _spineH(item.book).toDouble(),
      decoration: BoxDecoration(
        color: color,
        border: borderColor != null ? Border.all(color: borderColor, width: 1.5) : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: RotatedBox(
          quarterTurns: 3,
          child: Text(
            '${item.currentSlot}  ${item.book.title}',
            style: GoogleFonts.lora(
              fontSize: 10,
              color: const Color(0xFFF1ECE4),
              letterSpacing: 0.05,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final _SortItem item;
  const _Badge({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: item.isNF ? kRust : kGold),
      child: Text(
        item.isNF ? 'NON-FICTION' : '→ ${item.targetSlot}',
        style: GoogleFonts.lora(
          fontSize: 8,
          color: Colors.white,
          letterSpacing: 0.1,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.clip,
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final _SortItem item;
  const _ActionItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = item.isNF ? kRust : kGold;
    final instruction = item.isNF
        ? 'Non-fiction — reshelve in Dewey section'
        : 'Move from position ${item.currentSlot} → ${item.targetSlot}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 36,
            margin: const EdgeInsets.only(right: 10, top: 2),
            color: color,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.book.title,
                    style: kBody(12), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(instruction, style: kLabel(10, color: kTextMut)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
