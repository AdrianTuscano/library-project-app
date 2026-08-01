// ─────────────────────────────────────────────────────────────────────────────
// Library circulation status.
//
// The real implementation will talk to Georgetown PL's Biblionix Apollo system
// (ajax_backend or SIP2). For now, StubLibraryStatusService returns believable
// fake data so the UI can be built and tested end-to-end.
//
// To connect the real backend: implement LibraryStatusService and swap it in
// wherever StubLibraryStatusService is constructed.
// ─────────────────────────────────────────────────────────────────────────────

enum CircStatus { available, checkedOut, unknown }

class LibraryStatus {
  final CircStatus status;
  final String? callNumber;
  final String? dueDate;   // non-null when status == checkedOut

  const LibraryStatus({
    required this.status,
    this.callNumber,
    this.dueDate,
  });

  /// True when the system thinks this copy is checked out but it's physically
  /// sitting on the shelf — i.e. it was reshelved without being returned.
  bool get isReshelved => status == CircStatus.checkedOut;
}

// ── Interface ─────────────────────────────────────────────────────────────────

abstract class LibraryStatusService {
  /// Look up a single book by ISBN (used in Book scan mode).
  Future<LibraryStatus> checkByIsbn(String isbn);

  /// Look up by title + author (used for shelf scan results where we have no
  /// ISBN — Claude only returns title/author).
  Future<LibraryStatus> checkByTitle(String title, String author);
}

// ── Stub ──────────────────────────────────────────────────────────────────────

final libraryStatus = StubLibraryStatusService();

class StubLibraryStatusService implements LibraryStatusService {
  @override
  Future<LibraryStatus> checkByIsbn(String isbn) async {
    await Future.delayed(const Duration(milliseconds: 700));
    return _fromHash(isbn.codeUnits.fold(0, (a, c) => a + c));
  }

  @override
  Future<LibraryStatus> checkByTitle(String title, String author) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return _fromHash((title + author).codeUnits.fold(0, (a, c) => a + c));
  }

  LibraryStatus _fromHash(int hash) {
    switch (hash % 3) {
      case 0:
        return LibraryStatus(
          status: CircStatus.checkedOut,
          dueDate: _fakeDue(hash),
        );
      case 1:
        return LibraryStatus(
          status: CircStatus.available,
          callNumber: _fakeCallNumber(hash),
        );
      default:
        return const LibraryStatus(status: CircStatus.unknown);
    }
  }

  String _fakeDue(int hash) {
    final date = DateTime.now().add(Duration(days: 3 + hash % 21));
    const m = ['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[date.month - 1]} ${date.day}';
  }

  String _fakeCallNumber(int hash) {
    const letters = ['FIC', 'B', 'BIO', '813', '823', '914', '153'];
    return letters[hash % letters.length];
  }
}
