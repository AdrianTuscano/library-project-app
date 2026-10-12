import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'book_cache.dart';
import 'camera_screen.dart';
import 'design.dart';
import 'nav.dart';
import 'settings.dart';

List<CameraDescription> cameras = [];
final bookCache = BookCache();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  try {
    cameras = await availableCameras();
  } catch (_) {
    cameras = [];
  }
  await appSettings.load();
  await bookCache.init();
  if (kDebugMode) await bookCache.clear();
  runApp(const ShelfScanApp());
}

class ShelfScanApp extends StatefulWidget {
  const ShelfScanApp({super.key});

  @override
  State<ShelfScanApp> createState() => _ShelfScanAppState();
}

class _ShelfScanAppState extends State<ShelfScanApp> {
  @override
  void initState() {
    super.initState();
    appSettings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    appSettings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShelfScan',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kBgScreen,
        colorScheme: const ColorScheme.light(
          primary: kGoldText,
          onPrimary: Colors.white,
          surface: kBgScreen,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF201F1D),
          contentTextStyle: kBody(16, color: kOnDark),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      // Apply the in-app text size on top of the phone's own text size setting.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final system = mq.textScaler.scale(16) / 16;
        final scale = (system * appSettings.textSize.factor).clamp(0.85, 2.0);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        );
      },
      navigatorKey: navigatorKey,
      home: const CameraScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
