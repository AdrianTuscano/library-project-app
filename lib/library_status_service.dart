import 'z3950_catalog_service.dart';

enum CircStatus { available, checkedOut, unknown }

class LibraryStatus {
  final CircStatus status;
  final String? callNumber;

  const LibraryStatus({required this.status, this.callNumber});

  bool get isReshelved => status == CircStatus.checkedOut;
}

abstract class LibraryStatusService {
  Future<LibraryStatus> checkByIsbn(String isbn);
  /// [callNumber] is the spine sticker text, if OCR read one; used to pick the
  /// right edition/format among catalog matches.
  Future<LibraryStatus> checkByTitle(String title, String author, {String? callNumber});
}

// Not `final`, so a test can substitute a fake.
LibraryStatusService libraryStatus = Z3950LibraryStatusService();
