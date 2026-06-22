import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'book_results_screen.dart';
import 'book_scanner.dart';
import 'main.dart';

// Gap threshold — 20 px matched the Pi's webcam. If spines merge on the
// phone, raise this (try 50 → 100) without recompiling via the debug tab.
const double _kGapThreshold = 20;

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  _PermState _permState = _PermState.checking;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // Re-check permission when the user returns from Settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _permState == _PermState.denied) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final status = await Permission.camera.status;

    if (status.isGranted) {
      setState(() => _permState = _PermState.granted);
      await _initCamera();
      return;
    }

    if (status.isPermanentlyDenied) {
      setState(() => _permState = _PermState.denied);
      return;
    }

    // First-time or "ask again" — show system prompt.
    final result = await Permission.camera.request();
    if (result.isGranted) {
      setState(() => _permState = _PermState.granted);
      await _initCamera();
    } else {
      setState(() => _permState = _PermState.denied);
    }
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) return;
    final controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );
    await controller.initialize();
    if (!mounted) return;
    _controller = controller;
    setState(() {});
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final XFile imageFile = await controller.takePicture();
      final inputImage = InputImage.fromFilePath(imageFile.path);

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognized = await recognizer.processImage(inputImage);
      await recognizer.close();
      await File(imageFile.path).delete();

      // No text at all — stay on camera, show a tip.
      if (recognized.blocks.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No text detected — try better lighting or hold steadier'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

      // OCR done (fast, on-device). Kick off HTTP lookups without awaiting —
      // navigate now so the loading state is visible during the wait.
      final scanner = BookScanner();
      final clusterCount =
          scanner.clusterByGap(recognized, gapThreshold: _kGapThreshold).length;
      final resultsFuture = scanner.scanBooks(
        recognized,
        gapThreshold: _kGapThreshold,
        cache: bookCache,
      );

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookResultsScreen(
            resultsFuture: resultsFuture,
            rawText: recognized,
            gapThreshold: _kGapThreshold,
            clusterCount: clusterCount,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[CameraScreen] capture error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Capture failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_permState == _PermState.checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_permState == _PermState.denied) {
      return const _PermissionDeniedView();
    }

    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            CameraPreview(controller)
          else
            const Center(child: CircularProgressIndicator()),

          // Tip overlay.
          const Positioned(
            top: 56,
            left: 16,
            right: 16,
            child: Center(
              child: _PillLabel('Hold phone sideways — spines become vertical columns'),
            ),
          ),

          // Shutter button.
          Positioned(
            bottom: 52,
            left: 0,
            right: 0,
            child: Center(
              child: _ShutterButton(
                isCapturing: _isCapturing,
                onTap: _capture,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Permission denied view
// ─────────────────────────────────────────────────────────────────────────────

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                size: 72,
                color: Color(0xFF5C6270),
              ),
              const SizedBox(height: 28),
              const Text(
                'Camera Access Required',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'ShelfScan needs your camera to scan book spines. '
                'Your photos are processed on-device and never uploaded.',
                style: TextStyle(color: Color(0xFF9BA0AB), fontSize: 15, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 36),
              FilledButton.icon(
                onPressed: openAppSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('Open Settings'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF4E9BFF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small helpers
// ─────────────────────────────────────────────────────────────────────────────

enum _PermState { checking, granted, denied }

class _PillLabel extends StatelessWidget {
  final String text;
  const _PillLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isCapturing;
  final VoidCallback onTap;
  const _ShutterButton({required this.isCapturing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isCapturing ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isCapturing ? Colors.grey.shade700 : Colors.white,
          border: Border.all(color: Colors.white70, width: 4),
        ),
        child: isCapturing
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.black54,
                ),
              )
            : null,
      ),
    );
  }
}
