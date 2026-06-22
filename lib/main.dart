import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'book_cache.dart';
import 'camera_screen.dart';

List<CameraDescription> cameras = [];
final bookCache = BookCache();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  await bookCache.init();
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
