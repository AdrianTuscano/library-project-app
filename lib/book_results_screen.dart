import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'book_scanner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens
// ─────────────────────────────────────────────────────────────────────────────

const _bg = Color(0xFF0F1117);
const _cardBg = Color(0xFF1C1F28);
const _cardBorder = Color(0xFF272B36);
const _textPrimary = Colors.white;
const _textSecondary = Color(0xFF9BA0AB);
const _textTertiary = Color(0xFF5C6270);
const _accentBlue = Color(0xFF4E9BFF);
const _accentGreen = Color(0xFF30D158);
const _accentAmber = Color(0xFFFF9F0A);

// ─────────────────────────────────────────────────────────────────────────────
// Sort helpers
// ─────────────────────────────────────────────────────────────────────────────

enum _SortOrder { shelf, author, dewey }

List<BookResult> _applySort(List<BookResult> books, _SortOrder order) {
  final copy = List<BookResult>.from(books);
  switch (order) {
    case _SortOrder.shelf:
      copy.sort((a, b) => a.position.compareTo(b.position));
    case _SortOrder.author:
      copy.sort((a, b) => _lastName(a.author).compareTo(_lastName(b.author)));
    case _SortOrder.dewey:
      copy.sort((a, b) {
        final da = _deweyValue(a.callNumber);
        final db = _deweyValue(b.callNumber);
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });
  }
  return copy;
}

String _lastName(String author) {
  final parts = author.trim().split(RegExp(r'\s+'));
  return parts.isEmpty ? '' : parts.last.toUpperCase();
}

double? _deweyValue(String? callNumber) {
  if (callNumber == null) return null;
  final m = RegExp(r'^(\d{3}\.?\d*)').firstMatch(callNumber);
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class BookResultsScreen extends StatefulWidget {
  /// Changed from Future<List<BookResult>> to Future<ScanResult> so we also
  /// carry the isOffline flag through to the UI.
  final Future<ScanResult> resultsFuture;
  final RecognizedText rawText;
  final double gapThreshold;
  final int clusterCount;

  const BookResultsScreen({
    super.key,
    required this.resultsFuture,
    required this.rawText,
    required this.gapThreshold,
    required this.clusterCount,
  });

  @override
  State<BookResultsScreen> createState() => _BookResultsScreenState();
}

class _BookResultsScreenState extends State<BookResultsScreen> {
  _SortOrder _sortOrder = _SortOrder.shelf;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'ShelfScan',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, letterSpacing: -0.3),
        ),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _cardBorder),
        ),
      ),
      body: FutureBuilder<ScanResult>(
        future: widget.resultsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _LoadingView(clusterCount: widget.clusterCount);
          }
          if (snapshot.hasError) {
            return _ErrorView(error: snapshot.error.toString());
          }

          final scanResult = snapshot.data!;
          final books = scanResult.books;

          if (books.isEmpty) return const _EmptyView();

          final sorted = _applySort(books, _sortOrder);
          return _ResultsView(
            books: sorted,
            isOffline: scanResult.isOffline,
            sortOrder: _sortOrder,
            onSortChanged: (s) => setState(() => _sortOrder = s),
            rawText: widget.rawText,
            gapThreshold: widget.gapThreshold,
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Loading
// ─────────────────────────────────────────────────────────────────────────────

class _LoadingView extends StatefulWidget {
  final int clusterCount;
  const _LoadingView({required this.clusterCount});

  @override
  State<_LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<_LoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.clusterCount;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: _accentBlue,
              backgroundColor: _cardBorder,
            ),
          ),
          const SizedBox(height: 24),
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => Opacity(
              opacity: 0.55 + 0.45 * _pulse.value,
              child: Text(
                n > 0
                    ? 'Looking up $n book${n == 1 ? "" : "s"}…'
                    : 'Searching Open Library…',
                style: const TextStyle(
                  color: _textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Running parallel lookups',
            style: TextStyle(color: _textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_rounded, size: 64, color: _textTertiary),
            const SizedBox(height: 20),
            const Text(
              'No books detected',
              style: TextStyle(
                color: _textPrimary, fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            ...[
              (Icons.wb_sunny_outlined, 'Good, even lighting on the spines'),
              (Icons.do_not_touch_outlined, 'Hold the camera steady while capturing'),
              (Icons.crop_rotate, 'Spines should face the camera directly'),
              (Icons.smartphone, 'Phone sideways — spines become vertical columns'),
            ].map((t) => _TipRow(icon: t.$1, tip: t.$2)),
          ],
        ),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  final IconData icon;
  final String tip;
  const _TipRow({required this.icon, required this.tip});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: _accentBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(tip,
                style: const TextStyle(color: _textSecondary, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 48, color: Color(0xFFFF453A)),
            const SizedBox(height: 16),
            const Text(
              'Something went wrong',
              style: TextStyle(
                  color: _textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _textSecondary, fontSize: 13)),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go back',
                  style: TextStyle(color: _accentBlue)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Results list
// ─────────────────────────────────────────────────────────────────────────────

class _ResultsView extends StatelessWidget {
  final List<BookResult> books;
  final bool isOffline;
  final _SortOrder sortOrder;
  final ValueChanged<_SortOrder> onSortChanged;
  final RecognizedText rawText;
  final double gapThreshold;

  const _ResultsView({
    required this.books,
    required this.isOffline,
    required this.sortOrder,
    required this.onSortChanged,
    required this.rawText,
    required this.gapThreshold,
  });

  @override
  Widget build(BuildContext context) {
    final hasCached =
        books.any((b) => b.source == ResultSource.cache);
    final hasUnavailable =
        books.any((b) => b.source == ResultSource.unavailable);

    return CustomScrollView(
      slivers: [
        // ── Offline / cache banners ──────────────────────────────────────────
        if (isOffline || hasUnavailable || hasCached)
          SliverToBoxAdapter(
            child: _StatusBanner(
              isOffline: isOffline || hasUnavailable,
              hasCached: hasCached,
            ),
          ),

        // ── Sort controls ────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _SortBar(current: sortOrder, onChanged: onSortChanged),
        ),

        // ── Book cards ───────────────────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          sliver: SliverList.separated(
            itemCount: books.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _BookCard(
              book: books[i],
              isFirst: i == 0,
              isLast: i == books.length - 1,
            ),
          ),
        ),

        // ── Debug disclosure ─────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _DebugDisclosure(
              rawText: rawText, gapThreshold: gapThreshold),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status banner (offline / cached)
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final bool isOffline;
  final bool hasCached;
  const _StatusBanner({required this.isOffline, required this.hasCached});

  @override
  Widget build(BuildContext context) {
    final String message;
    final Color color;
    final IconData icon;

    if (isOffline) {
      message = hasCached
          ? 'No network — some results are from cache'
          : 'No network — lookup unavailable. Results show detected text.';
      color = _accentAmber;
      icon = Icons.wifi_off_rounded;
    } else {
      message = 'Some results served from cache';
      color = _accentBlue;
      icon = Icons.bolt_rounded;
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sort bar
// ─────────────────────────────────────────────────────────────────────────────

class _SortBar extends StatelessWidget {
  final _SortOrder current;
  final ValueChanged<_SortOrder> onChanged;
  const _SortBar({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Text('Sort by',
              style: TextStyle(
                  color: _textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 12),
          Expanded(
            child: SegmentedButton<_SortOrder>(
              selected: {current},
              onSelectionChanged: (s) => onChanged(s.first),
              showSelectedIcon: false,
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((s) =>
                    s.contains(WidgetState.selected)
                        ? _accentBlue.withOpacity(0.18)
                        : _cardBg),
                foregroundColor: WidgetStateProperty.resolveWith((s) =>
                    s.contains(WidgetState.selected) ? _accentBlue : _textSecondary),
                side: WidgetStateProperty.all(
                    const BorderSide(color: _cardBorder)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              segments: const [
                ButtonSegment(value: _SortOrder.shelf, label: Text('Shelf')),
                ButtonSegment(value: _SortOrder.author, label: Text('Author')),
                ButtonSegment(value: _SortOrder.dewey, label: Text('Dewey')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Book card
// ─────────────────────────────────────────────────────────────────────────────

class _BookCard extends StatelessWidget {
  final BookResult book;
  final bool isFirst;
  final bool isLast;

  const _BookCard({required this.book, required this.isFirst, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final isUnavailable = book.source == ResultSource.unavailable;

    return Container(
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _cardBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Position + source badges ──
          Row(
            children: [
              _PositionBadge(position: book.position, isBottom: isFirst, isTop: isLast),
              const SizedBox(width: 6),
              if (book.source == ResultSource.cache)
                _TagBadge(label: 'Cached', color: _accentBlue),
              if (isUnavailable)
                _TagBadge(label: 'No network', color: _accentAmber),
              const Spacer(),
              if (!isUnavailable) _ConfidenceDot(confidence: book.confidence),
            ],
          ),
          const SizedBox(height: 12),

          // ── Title ──
          Text(
            book.title,
            style: TextStyle(
              color: isUnavailable ? _textSecondary : _textPrimary,
              fontSize: isUnavailable ? 14 : 16,
              fontWeight: FontWeight.w700,
              height: 1.3,
              letterSpacing: -0.2,
              fontStyle: isUnavailable ? FontStyle.italic : FontStyle.normal,
            ),
          ),

          // ── Author ──
          if (book.author.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(book.author,
                style: const TextStyle(color: _textSecondary, fontSize: 14)),
          ],

          // ── Year + call number ──
          if (book.firstPublishYear != null || book.callNumber != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (book.firstPublishYear != null)
                  _MetaTag(label: book.firstPublishYear!),
                if (book.callNumber != null)
                  _MetaTag(label: book.callNumber!, isCallNumber: true),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PositionBadge extends StatelessWidget {
  final int position;
  final bool isBottom;
  final bool isTop;
  const _PositionBadge(
      {required this.position, required this.isBottom, required this.isTop});

  @override
  Widget build(BuildContext context) {
    String label = '#$position';
    if (isBottom) label += '  Bottom';
    if (isTop) label += '  Top';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _accentBlue.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _accentBlue.withOpacity(0.35)),
      ),
      child: Text(label,
          style: const TextStyle(
              color: _accentBlue,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2)),
    );
  }
}

class _TagBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _TagBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}

class _ConfidenceDot extends StatelessWidget {
  final String confidence;
  const _ConfidenceDot({required this.confidence});

  @override
  Widget build(BuildContext context) {
    final isHigh = confidence == 'high';
    final color = isHigh ? _accentGreen : _accentAmber;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        const SizedBox(width: 5),
        Text(isHigh ? 'High match' : 'Possible match',
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _MetaTag extends StatelessWidget {
  final String label;
  final bool isCallNumber;
  const _MetaTag({required this.label, this.isCallNumber = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isCallNumber
            ? const Color(0xFF7B5EA7).withOpacity(0.15)
            : Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isCallNumber
              ? const Color(0xFF7B5EA7).withOpacity(0.4)
              : Colors.white.withOpacity(0.1),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isCallNumber ? const Color(0xFFBB9FE2) : _textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          fontFamily: isCallNumber ? 'monospace' : null,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Debug disclosure (collapsed by default)
// ─────────────────────────────────────────────────────────────────────────────

class _DebugDisclosure extends StatefulWidget {
  final RecognizedText rawText;
  final double gapThreshold;
  const _DebugDisclosure({required this.rawText, required this.gapThreshold});

  @override
  State<_DebugDisclosure> createState() => _DebugDisclosureState();
}

class _DebugDisclosureState extends State<_DebugDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scanner = BookScanner();
    final clusters =
        scanner.clusterByGap(widget.rawText, gapThreshold: widget.gapThreshold);
    final totalWords = widget.rawText.blocks.fold(
        0, (n, b) => n + b.lines.fold(0, (m, l) => m + l.elements.length));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Text(
                  'Debug — ${clusters.length} clusters · $totalWords words · gap ${widget.gapThreshold.toStringAsFixed(0)} px',
                  style: const TextStyle(color: _textTertiary, fontSize: 11),
                ),
                const Spacer(),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: _textTertiary,
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 10),
            ...clusters.asMap().entries.map(
                (e) => _ClusterDebugCard(index: e.key, cluster: e.value)),
          ],
        ],
      ),
    );
  }
}

class _ClusterDebugCard extends StatelessWidget {
  final int index;
  final List<ScanWord> cluster;
  const _ClusterDebugCard({required this.index, required this.cluster});

  @override
  Widget build(BuildContext context) {
    final minX =
        cluster.map((w) => w.centerX).reduce((a, b) => a < b ? a : b);
    final maxX =
        cluster.map((w) => w.centerX).reduce((a, b) => a > b ? a : b);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cluster ${index + 1}  ·  x ${minX.toStringAsFixed(0)}–${maxX.toStringAsFixed(0)}',
            style: const TextStyle(
                color: _textTertiary, fontSize: 10, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 4,
            children: cluster.map((w) {
              return Tooltip(
                message: 'x=${w.centerX.toStringAsFixed(0)}',
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: _cardBorder),
                  ),
                  child: Text(w.text,
                      style:
                          const TextStyle(color: _textSecondary, fontSize: 11)),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
