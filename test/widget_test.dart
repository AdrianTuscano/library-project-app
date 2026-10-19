// The previous test here was unmodified `flutter create` boilerplate — it
// pumped ShelfScanApp and looked for a counter FAB that was never part of
// this app, so it always failed. This replaces it with a real smoke test:
// mock the camera-permission channel to "denied" (no camera/platform
// dependency needed) and confirm the app actually reaches the screen it's
// supposed to show for that case, instead of crashing or hanging.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf_scan/main.dart';

void main() {
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return 0; // PermissionStatus.denied
        case 'requestPermissions':
          return {1: 0}; // {Permission.camera.value: PermissionStatus.denied}
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('shows the camera-permission screen when camera access is denied',
      (tester) async {
    await tester.pumpWidget(const ShelfScanApp());
    await tester.pumpAndSettle();

    expect(find.text('Shelver Helper needs your camera'), findsOneWidget);
  });
}
