import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'design.dart';
import 'library_status_service.dart';
import 'widgets.dart';

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
    debugPrint('[BookScanScreen] loading for scanned barcode "${widget.isbn}"');
    try {
      final (info, isbnStatus) = (
        await _fetchBookInfo(widget.isbn),
        await libraryStatus.checkByIsbn(widget.isbn),
      );
      debugPrint('[BookScanScreen] info=$info, checkByIsbn status=${isbnStatus.status}');

      // Exact-ISBN lookups are fragile: publishers reprint the same book
      // under a new ISBN constantly, so the barcode on this physical copy
      // may not be the ISBN the library happened to catalog. If it came
      // back empty but Open Library gave us a title, retry the way shelf
      // scanning already does — by title/author, which matches regardless
      // of edition.
      var status = isbnStatus;
      if (status.status == CircStatus.unknown && (info?.title.isNotEmpty ?? false)) {
        debugPrint('[BookScanScreen] ISBN came back unknown; retrying by title "${info!.title}"');
        status = await libraryStatus.checkByTitle(info.title, info.author);
        debugPrint('[BookScanScreen] checkByTitle status=${status.status}');
      }

      if (!mounted) return;
      setState(() {
        _info = info;
        _status = status;
      });
    } catch (e) {
      debugPrint('[BookScanScreen] load FAILED: $e');
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = _error == null && _status == null;
    return Scaffold(
      backgroundColor: kBgDark,
      body: SafeArea(
        child: Column(
          children: [
            AppTopBar(
              title: loading ? 'Looking up your book…' : (_info?.title ?? 'Your book'),
              subtitle: 'Barcode scan',
              onBack: () => Navigator.pop(context),
              backLabel: 'Scan',
              onDark: true,
            ),
            Expanded(
              child: _error != null
                  ? _buildError()
                  : loading
                      ? _buildLoading()
                      : _buildResult(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: kGold, strokeWidth: 3),
            const SizedBox(height: 18),
            Semantics(
              liveRegion: true,
              child: Text('Looking up your book…', style: kBody(18, color: kOnDarkMut)),
            ),
          ],
        ),
      );

  Widget _buildResult() {
    final info = _info;
    final status = _status!;
    final landscape = isLandscape(context);

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(info?.title ?? 'We could not find this book\'s name',
              style: kHeading(30, color: kOnDark)),
        ),
        if (info != null && info.author.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('by ${info.author}', style: kBody(18, color: kOnDarkMut)),
        ],
        const SizedBox(height: 18),
        Wrap(
          spacing: 28,
          runSpacing: 14,
          children: [
            if (status.callNumber != null)
              InfoField(
                  label: 'Call number', value: status.callNumber!, onDark: true, callNumber: true),
            if (info?.publishYear != null)
              InfoField(label: 'Published', value: info!.publishYear!, onDark: true),
            if (info?.publisher != null)
              InfoField(label: 'Publisher', value: info!.publisher!, onDark: true),
            InfoField(label: 'Barcode number', value: widget.isbn, onDark: true),
          ],
        ),
      ],
    );

    final statusBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusCard(status: status, onDark: true),
        if (status.isReshelved) ...[
          const SizedBox(height: 12),
          const ReshelveCard(onDark: true),
        ],
        const SizedBox(height: 20),
        AppButton(
          label: 'Scan another book',
          icon: Icons.barcode_reader,
          onDark: true,
          expand: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: landscape
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: details),
                const SizedBox(width: 24),
                SizedBox(width: 360, child: statusBlock),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [details, const SizedBox(height: 22), statusBlock],
            ),
    );
  }

  Widget _buildError() {
    debugPrint('[BookScan] lookup error: $_error');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Something went wrong',
                  textAlign: TextAlign.center, style: kHeading(28, color: kOnDark)),
              const SizedBox(height: 10),
              Text('Check that your phone is online, then try again.',
                  textAlign: TextAlign.center, style: kBody(18, color: kOnDarkMut)),
              const SizedBox(height: 28),
              AppButton(
                label: 'Try again',
                icon: Icons.barcode_reader,
                onDark: true,
                expand: true,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
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
