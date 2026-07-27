import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'book_cache.dart';
import 'camera_screen.dart';

List<CameraDescription> cameras = [];
final bookCache = BookCache();

// TESTING: set true to wipe the on-device book cache on launch, so repeat
// scans always hit a fresh Open Library lookup. Set back to false for demos.
const bool kClearCacheOnLaunch = true;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to ONE landscape orientation so the camera sensor never flips
  // mid-session. landscapeLeft = charging port on the LEFT. If your port ends
  // up on the right, change this single value to landscapeRight.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  cameras = await availableCameras();
  await bookCache.init();
  if (kClearCacheOnLaunch) await bookCache.clear();
  runApp(const ShelfScanApp());
}

class ShelfScanApp extends StatelessWidget {
  const ShelfScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShelfScan',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4E9BFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F1117),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const CameraScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
