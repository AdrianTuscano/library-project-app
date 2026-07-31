import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'book_cache.dart';
import 'camera_screen.dart';
import 'design.dart';

List<CameraDescription> cameras = [];
final bookCache = BookCache();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  try {
    cameras = await availableCameras();
  } catch (_) {
    cameras = [];
  }
  await bookCache.init();
  if (kDebugMode) await bookCache.clear();
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
        scaffoldBackgroundColor: kBgScreen,
        colorScheme: const ColorScheme.light(
          primary: kGold,
          onPrimary: Colors.white,
          surface: kBgScreen,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF201F1D),
          contentTextStyle: kBody(13, color: const Color(0xFFEFE9E0)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const CameraScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
