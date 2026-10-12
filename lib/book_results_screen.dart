import 'package:flutter/material.dart';
import 'book_scanner.dart';
import 'claude_ocr.dart' show NoBooksFoundException;
import 'design.dart';
import 'library_status_service.dart';
import 'settings.dart';
import 'shelf_sort_view.dart';
import 'widgets.dart';

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

  final Map<int, LibraryStatus> _statuses = {};
  // Ticks whenever a status arrives, so an open order check can refresh.
  final _statusUpdates = ValueNotifier<int>(0);

  @override
  void dispose() {
    _statusUpdates.dispose();
    super.dispose();
  }

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
    Future.microtask(() async {
      for (var i = 1; i <= _placeholders.length; i++) {
        await Future.delayed(const Duration(milliseconds: 160));
        if (!mounted) return;
        setState(() => _revealed = i);
      }
    });

    widget.resultsFuture.then((result) {
      if (!mounted) return;
      setState(() => _result = result);
      _checkAllStatuses(result.books);
    }).catchError((Object e) {
      if (!mounted) return;
      if (e is NoBooksFoundException) {
        setState(() => _noBooks = true);
      } else {
        setState(() => _error = e.toString());
      }
    });
  }

  void _checkAllStatuses(List<BookResult> books) {
    for (final book in books) {
      libraryStatus
          .checkByTitle(book.title, book.author, callNumber: book.callNumber)
          .then((status) {
        if (!mounted) return;
        setState(() => _statuses[book.position] = status);
        _statusUpdates.value++;
      }).catchError((_) {});
    }
  }

  void _select(int i, int count) {
    final next = i.clamp(0, count - 1);
    if (next == _selected) return;
    setState(() => _selected = next);
    final ctx = _spineKeys[next]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          alignment: 0.5, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  final Map<int, GlobalKey> _spineKeys = {};

  @override
  Widget build(BuildContext context) {
    if (_noBooks) return _buildNoBooks();
    if (_error != null) return _buildError();
    if (_result == null) return _buildProcessing();
    if (_result!.books.isEmpty) return _buildNoBooks();
    return _buildShelf(_result!.books);
  }

  Widget _placeholderShelf({required bool animate}) {
    return MediaQuery.withNoTextScaling(
      // Scale down to fit narrow (portrait) screens.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          height: 180,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < _placeholders.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(right: 6),
                  width: _placeholders[i].w,
                  height: _placeholders[i].h,
                  color: animate && i < _revealed
                      ? _placeholders[i].c
                      : const Color(0xFF26241F),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _darkPage(List<Widget> children) {
    return Scaffold(
      backgroundColor: kBgDark,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessing() {
    final allRevealed = _revealed >= _placeholders.length;
    return _darkPage([
      _placeholderShelf(animate: true),
      const SizedBox(height: 28),
      Semantics(
        liveRegion: true,
        child: Text(
          allRevealed ? 'Looking up each book…' : 'Reading the book spines…',
          textAlign: TextAlign.center,
          style: kHeading(28, color: kOnDark),
        ),
      ),
      const SizedBox(height: 8),
      Text('This takes a few seconds.',
          textAlign: TextAlign.center, style: kBody(17, color: kOnDarkMut)),
    ]);
  }

  Widget _buildNoBooks() {
    Widget tip(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(text, style: kBody(18, color: kOnDark)),
        );

    return _darkPage([
      _placeholderShelf(animate: false),
      const SizedBox(height: 28),
      Text('No books found',
          textAlign: TextAlign.center, style: kHeading(28, color: kOnDark)),
      const SizedBox(height: 16),
      tip('Use more light'),
      tip('Hold the phone still'),
      tip('Fit one row of books inside the box'),
      const SizedBox(height: 24),
      AppButton(
        label: 'Try again',
        icon: Icons.photo_camera_rounded,
        onDark: true,
        expand: true,
        onPressed: () => Navigator.pop(context),
      ),
    ]);
  }

  Widget _buildError() {
    debugPrint('[BookResults] scan error: $_error');
    return _darkPage([
      Text('Something went wrong',
          textAlign: TextAlign.center, style: kHeading(28, color: kOnDark)),
      const SizedBox(height: 10),
      Text('Check that your phone is online, then try again.',
          textAlign: TextAlign.center, style: kBody(18, color: kOnDarkMut)),
      const SizedBox(height: 28),
      AppButton(
        label: 'Try again',
        icon: Icons.photo_camera_rounded,
        onDark: true,
        expand: true,
        onPressed: () => Navigator.pop(context),
      ),
    ]);
  }

  void _openSortCheck(List<BookResult> books) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ShelfSortScreen(
          books: books,
          statuses: _statuses,
          statusUpdates: _statusUpdates,
        ),
      ),
    );
  }

  Widget _buildShelf(List<BookResult> books) {
    final landscape = isLandscape(context);
    final sel = _selected.clamp(0, books.length - 1);

    return Scaffold(
      backgroundColor: kBgScreen,
      body: SafeArea(
        child: Column(
          children: [
            AppTopBar(
              title: 'Your shelf',
              subtitle: books.length == 1 ? '1 book found' : '${books.length} books found',
              onBack: () => Navigator.pop(context),
              backLabel: 'New scan',
            ),
            Expanded(
              child: landscape
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, c) => SingleChildScrollView(
                              child: _buildSpineArea(books,
                                  spinesHeight: (c.maxHeight - 120).clamp(160.0, 230.0)),
                            ),
                          ),
                        ),
                        Container(
                          width: 380,
                          decoration: const BoxDecoration(
                            color: kBgPanel,
                            border: Border(left: BorderSide(color: kDivider)),
                          ),
                          child: SingleChildScrollView(child: _buildDetailPanel(books, sel)),
                        ),
                      ],
                    )
                  // Portrait: one scrolling page, so large text never overflows.
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildSpineArea(books, spinesHeight: 220),
                          Container(
                            decoration: const BoxDecoration(
                              color: kBgPanel,
                              border: Border(top: BorderSide(color: kDivider)),
                            ),
                            child: _buildDetailPanel(books, sel),
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

  Widget _buildSpineArea(List<BookResult> books, {required double spinesHeight}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('Tap a book to see more',
                    style: kLabel(17, color: kText, weight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: StatusLegend(),
        ),
        SizedBox(
          height: spinesHeight,
          child: Builder(builder: (context) {
            // Shrink the spines to fit short screens (landscape phones).
            final scale = ((spinesHeight - 24) / 200).clamp(0.45, 1.0);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < books.length; i++)
                    _SpineBar(
                      key: _spineKeys.putIfAbsent(i, GlobalKey.new),
                      book: books[i],
                      scale: scale,
                      selected: i == _selected,
                      status: _statuses[books[i].position],
                      onTap: () {
                        tapFeedback();
                        _select(i, books.length);
                      },
                    ),
                ],
              ),
            );
          }),
        ),
        Container(height: 8, color: const Color(0xFFCFC9C2)),
      ],
    );
  }

  Widget _buildDetailPanel(List<BookResult> books, int index) {
    final b = books[index];
    final status = _statuses[b.position];

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Previous',
                  icon: Icons.chevron_left_rounded,
                  kind: AppButtonKind.secondary,
                  onPressed: index > 0 ? () => _select(index - 1, books.length) : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('${index + 1} of ${books.length}',
                    style: kLabel(16, color: kTextMut, weight: FontWeight.w600)),
              ),
              Expanded(
                child: AppButton(
                  label: 'Next',
                  icon: Icons.chevron_right_rounded,
                  kind: AppButtonKind.secondary,
                  onPressed: index < books.length - 1
                      ? () => _select(index + 1, books.length)
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: Text(b.title, style: kHeading(28)),
          ),
          if (b.author.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('by ${b.author}', style: kBody(18, color: kTextMut)),
          ],
          const SizedBox(height: 16),
          StatusCard(status: status),
          if (status?.isReshelved == true) ...[
            const SizedBox(height: 12),
            const ReshelveCard(),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 28,
            runSpacing: 14,
            children: [
              if (b.callNumber != null)
                InfoField(label: 'Call number', value: b.callNumber!, callNumber: true),
              if (b.firstPublishYear != null)
                InfoField(label: 'First published', value: b.firstPublishYear!),
              InfoField(
                label: 'Title match',
                value: b.confidence == 'high' ? 'Very sure' : 'Not sure, please check',
              ),
            ],
          ),
          const SizedBox(height: 26),
          AppButton(
            label: 'What to do',
            icon: Icons.checklist_rounded,
            expand: true,
            onPressed: () => _openSortCheck(books),
          ),
          const SizedBox(height: 10),
          AppButton(
            label: 'Scan another shelf',
            icon: Icons.photo_camera_rounded,
            kind: AppButtonKind.secondary,
            expand: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}

class _SpineBar extends StatelessWidget {
  final BookResult book;
  final double scale;
  final bool selected;
  final LibraryStatus? status;
  final VoidCallback onTap;

  const _SpineBar({
    super.key,
    required this.book,
    required this.scale,
    required this.selected,
    required this.onTap,
    this.status,
  });

  @override
  Widget build(BuildContext context) {
    final w = spineWidth(book.title).toDouble();
    final h = spineHeight(book.title, book.author) * scale;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Book ${book.position}: ${book.title}. ${statusLook(status).word}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 180),
            offset: Offset(0, selected ? -0.06 : 0),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    color: spineColor(book.position),
                    border: selected ? Border.all(color: kGold, width: 3.5) : null,
                    boxShadow: selected
                        ? const [BoxShadow(color: Color(0x55000000), blurRadius: 8, offset: Offset(0, 3))]
                        : null,
                  ),
                  padding: const EdgeInsets.only(top: 30, bottom: 8),
                  child: Center(
                    child: RotatedBox(
                      quarterTurns: 3,
                      // Decorative label; the full title is in the panel, so it
                      // doesn't grow with text size and overflow the spine.
                      child: MediaQuery.withNoTextScaling(
                        child: Text(
                          '${book.position}  ${book.title}',
                          style: kLabel(13, color: const Color(0xFFF7F2EA), weight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(top: 4, child: StatusDot(status: status)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
