import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'book_results_screen.dart' show lastName, isNonFiction, deweyValue;
import 'book_scanner.dart';
import 'design.dart';
import 'library_status_service.dart';
import 'widgets.dart';

const _kNonFiction = Color(0xFF3F4A52);

/// What to do with one book, most urgent first.
enum _Fix { circulation, nonFiction, move, unknown, none }

class _SortItem {
  final BookResult book;
  final int currentSlot;
  final int? targetSlot; // physical spot it belongs in; null when it leaves the shelf
  final _Fix fix;

  const _SortItem(this.book, this.currentSlot, this.targetSlot, this.fix);

  bool get leaves => fix == _Fix.circulation || fix == _Fix.nonFiction;
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

/// Books the catalog says are checked out (or otherwise not on the shelf) go
/// to circulation; non-fiction goes to its own section. The fiction that stays
/// is ordered A–Z, and each book's target is the physical spot currently held
/// by the book that should be there, so spot numbers match the photo.
List<_SortItem> _computeSort(List<BookResult> books, Map<int, LibraryStatus> statuses) {
  bool toCirculation(BookResult b) => statuses[b.position]?.status == CircStatus.checkedOut;

  final staying = [
    for (var i = 0; i < books.length; i++)
      if (!toCirculation(books[i]) && !_isNonFiction(books[i])) i,
  ];
  final sorted = [...staying]..sort((a, b) => _sortKey(books[a]).compareTo(_sortKey(books[b])));
  final targetByIndex = {
    for (var k = 0; k < sorted.length; k++) sorted[k]: staying[k] + 1,
  };

  return List.generate(books.length, (i) {
    final b = books[i];
    if (toCirculation(b)) return _SortItem(b, i + 1, null, _Fix.circulation);
    if (_isNonFiction(b)) return _SortItem(b, i + 1, null, _Fix.nonFiction);
    final target = targetByIndex[i]!;
    if (target != i + 1) return _SortItem(b, i + 1, target, _Fix.move);
    final unknown = statuses[b.position]?.status == CircStatus.unknown;
    return _SortItem(b, i + 1, target, unknown ? _Fix.unknown : _Fix.none);
  });
}

int _spineW(BookResult b) => spineWidth(b.title);
int _spineH(BookResult b) => spineHeight(b.title, b.author);

class ShelfSortScreen extends StatelessWidget {
  final List<BookResult> books;
  final Map<int, LibraryStatus> statuses;
  /// Fires whenever another catalog status arrives.
  final Listenable statusUpdates;

  const ShelfSortScreen({
    super.key,
    required this.books,
    required this.statuses,
    required this.statusUpdates,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: statusUpdates,
      builder: (context, _) => _ShelfSortBody(
        books: books,
        items: _computeSort(books, statuses),
        pending: books.where((b) => !statuses.containsKey(b.position)).length,
      ),
    );
  }
}

class _ShelfSortBody extends StatelessWidget {
  final List<BookResult> books;
  final List<_SortItem> items;
  final int pending;

  const _ShelfSortBody({required this.books, required this.items, required this.pending});

  @override
  Widget build(BuildContext context) {
    final todo = [...items.where((it) => it.fix != _Fix.none)]
      ..sort((a, b) => a.fix.index.compareTo(b.fix.index));
    final landscape = isLandscape(context);
    final n = books.length;
    final needing = todo.where((it) => it.fix != _Fix.unknown).length;

    final actions = _ActionList(todo: todo, pending: pending);

    return Scaffold(
      backgroundColor: kBgScreen,
      body: SafeArea(
        child: Column(
          children: [
            AppTopBar(
              title: 'What to do',
              subtitle: needing == 0
                  ? (pending > 0 ? 'Checking with the library…' : 'All books are in order')
                  : '$needing of $n books need attention',
              onBack: () => Navigator.pop(context),
              backLabel: 'My shelf',
            ),
            Expanded(
              child: landscape
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, c) => SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const _OrderHint(),
                                  SizedBox(
                                    height: math.max(220, c.maxHeight - 70),
                                    child: _ShelfDrawing(items: items),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Container(
                          width: 380,
                          decoration: const BoxDecoration(
                            color: kBgPanel,
                            border: Border(left: BorderSide(color: kDivider)),
                          ),
                          child: SingleChildScrollView(child: actions),
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _OrderHint(),
                          SizedBox(height: 300, child: _ShelfDrawing(items: items)),
                          Container(
                            decoration: const BoxDecoration(
                              color: kBgPanel,
                              border: Border(top: BorderSide(color: kDivider)),
                            ),
                            child: actions,
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderHint extends StatelessWidget {
  const _OrderHint();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text("Story books go A to Z by the author's last name.",
                  style: kBody(16, color: kText)),
            ),
          ],
        ),
      );
}

class _ShelfDrawing extends StatelessWidget {
  final List<_SortItem> items;
  const _ShelfDrawing({required this.items});

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, c) => _build(c));

  Widget _build(BoxConstraints constraints) {
    if (items.isEmpty) return const SizedBox.shrink();

    final widths = items.map((it) => _spineW(it.book).toDouble()).toList();
    const gap = 8.0;
    const arcZoneH = 72.0;
    const badgeH = 30.0;
    const shelfLineH = 8.0;
    const bottomPad = 6.0;
    final rawMaxH = items.map((it) => _spineH(it.book).toDouble()).fold(0.0, math.max);
    // Shrink spines so arcs, badges and books fit the available height.
    final scale = ((constraints.maxHeight - arcZoneH - badgeH - shelfLineH - bottomPad) / rawMaxH)
        .clamp(0.4, 1.0);
    double spineH(int i) => _spineH(items[i].book) * scale;
    final maxSpineH = rawMaxH * scale;

    final totalH = arcZoneH + badgeH + maxSpineH + shelfLineH + bottomPad;

    final xs = <double>[];
    double cx = 0;
    for (final w in widths) {
      xs.add(cx);
      cx += w + gap;
    }
    final totalW = cx - gap + 20;

    double centerX(int i) => xs[i] + widths[i] / 2;
    double spineTopY(int i) => arcZoneH + badgeH + (maxSpineH - spineH(i));

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(left: 16),
      child: SizedBox(
        width: math.max(totalW, constraints.maxWidth - 16),
        height: totalH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ArcPainter(
                  items: items,
                  centerXs: List.generate(items.length, centerX),
                  spineTopYs: List.generate(items.length, spineTopY),
                ),
              ),
            ),
            for (var i = 0; i < items.length; i++)
              if (items[i].fix != _Fix.none)
                Positioned(
                  top: arcZoneH + 2,
                  left: xs[i] - 6,
                  width: widths[i] + 12,
                  child: _Badge(item: items[i]),
                ),
            for (var i = 0; i < items.length; i++)
              Positioned(
                top: spineTopY(i),
                left: xs[i],
                child: _SortSpine(item: items[i], height: spineH(i)),
              ),
            Positioned(
              top: arcZoneH + badgeH + maxSpineH,
              left: 0,
              width: math.max(totalW, constraints.maxWidth),
              child: Container(height: shelfLineH, color: kShelfLine),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionList extends StatelessWidget {
  final List<_SortItem> todo;
  final int pending;
  const _ActionList({required this.todo, required this.pending});

  @override
  Widget build(BuildContext context) {
    final cartCount = todo.where((it) => it.leaves).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pending > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: kGoldText),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Still checking $pending ${pending == 1 ? 'book' : 'books'} with the library. '
                    'This list will update.',
                    style: kBody(16, color: kTextMut),
                  ),
                ),
              ],
            ),
          ),
        if (cartCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Put $cartCount ${cartCount == 1 ? 'book' : 'books'} on your cart',
                    style: kLabel(18, color: kRust, weight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        if (todo.isEmpty && pending == 0)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text('All books are in order',
                    textAlign: TextAlign.center,
                    style: kLabel(20, color: kText, weight: FontWeight.w600)),
                Text('Nothing needs to move.',
                    textAlign: TextAlign.center, style: kBody(17, color: kTextMut)),
              ],
            ),
          ),
        for (var i = 0; i < todo.length; i++) ...[
          if (i > 0) const Divider(color: kDivider, height: 1),
          _ActionItem(item: todo[i]),
        ],
        const Divider(color: kDivider, height: 1),
        Padding(
          padding: const EdgeInsets.all(14),
          child: AppButton(
            label: 'Scan another shelf',
            icon: Icons.photo_camera_rounded,
            expand: true,
            onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
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
      if (item.fix == _Fix.none || item.fix == _Fix.unknown) continue;

      final x1 = centerXs[i];
      final y1 = spineTopYs[i];

      if (item.leaves) {
        _drawSectionArrow(canvas, x1, y1, item.fix == _Fix.circulation ? kRust : _kNonFiction);
      } else {
        final j = item.targetSlot! - 1;
        if (j < 0 || j >= centerXs.length) continue;
        _drawArc(canvas, x1, y1, centerXs[j], spineTopYs[j]);
      }
    }
  }

  void _drawSectionArrow(Canvas canvas, double cx, double spineTop, Color color) {
    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(cx, spineTop), Offset(cx, spineTop - 56), strokePaint);

    final fillPaint = Paint()..color = color..style = PaintingStyle.fill;
    final arrowHead = Path()
      ..moveTo(cx, spineTop - 61)
      ..lineTo(cx - 5, spineTop - 50)
      ..lineTo(cx + 5, spineTop - 50)
      ..close();
    canvas.drawPath(arrowHead, fillPaint);
  }

  void _drawArc(Canvas canvas, double x1, double y1, double x2, double y2) {
    final paint = Paint()
      ..color = kGoldText
      ..strokeWidth = 2.5
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

    final fillPaint = Paint()..color = kGoldText..style = PaintingStyle.fill;
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


(Color, IconData?) _fixLook(_Fix fix) => switch (fix) {
      _Fix.circulation => (kRust, Icons.shopping_cart_rounded),
      _Fix.nonFiction => (_kNonFiction, Icons.north_rounded),
      _Fix.move => (kGoldText, null),
      _Fix.unknown => (kTextMut, Icons.help_rounded),
      _Fix.none => (kTextMut, null),
    };

class _SortSpine extends StatelessWidget {
  final _SortItem item;
  final double height;
  const _SortSpine({required this.item, required this.height});

  @override
  Widget build(BuildContext context) {
    final borderColor = item.fix == _Fix.none ? null : _fixLook(item.fix).$1;

    return Container(
      width: _spineW(item.book).toDouble(),
      height: height,
      decoration: BoxDecoration(
        color: spineColor(item.book.position),
        border: borderColor != null ? Border.all(color: borderColor, width: 3) : null,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: RotatedBox(
          quarterTurns: 3,
          child: MediaQuery.withNoTextScaling(
            child: Text(
              '${item.currentSlot}  ${item.book.title}',
              style: kLabel(13, color: kSpineLabel, weight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
    final (color, icon) = _fixLook(item.fix);
    return MediaQuery.withNoTextScaling(
      child: Container(
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        padding: icon == null ? const EdgeInsets.symmetric(horizontal: 5) : EdgeInsets.zero,
        child: icon != null
            ? Icon(icon, color: Colors.white, size: 18)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 14),
                  const SizedBox(width: 2),
                  Text(
                    '${item.targetSlot}',
                    style: kLabel(15, color: Colors.white, weight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  ),
                ],
              ),
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final _SortItem item;
  const _ActionItem({required this.item});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _fixLook(item.fix);
    final instruction = switch (item.fix) {
      _Fix.circulation =>
        'The library says this book is checked out, but it is here. '
            'Put it on your cart and take it to circulation.',
      _Fix.nonFiction => 'This is non-fiction. Put it on your cart for the non-fiction shelves.',
      _Fix.move => 'Move it from spot ${item.currentSlot} to spot ${item.targetSlot}.',
      _Fix.unknown =>
        'We could not find this book at the library. Check the title, or ask at circulation.',
      _Fix.none => '',
    };

    return Semantics(
      label: 'Book ${item.currentSlot}, ${item.book.title}. $instruction',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: color,
              child: icon != null
                  ? Icon(icon, color: Colors.white, size: 22)
                  : MediaQuery.withNoTextScaling(
                      child: Text('${item.currentSlot}',
                          style: kLabel(17, color: Colors.white, weight: FontWeight.w700)),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${item.currentSlot}. ${item.book.title}',
                      style: kLabel(18, color: kText, weight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(instruction, style: kBody(16, color: color)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
