import 'apollo_catalog_service.dart';

enum CircStatus { available, checkedOut, unknown }

class LibraryStatus {
  final CircStatus status;
  final String? callNumber;
  final String? dueDate; // non-null when checkedOut

  const LibraryStatus({required this.status, this.callNumber, this.dueDate});

  bool get isReshelved => status == CircStatus.checkedOut;
}

abstract class LibraryStatusService {
  Future<LibraryStatus> checkByIsbn(String isbn);
  Future<LibraryStatus> checkByTitle(String title, String author);
}

final libraryStatus = ApolloLibraryStatusService();
