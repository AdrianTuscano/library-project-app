import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'book_results_screen.dart';
import 'book_scanner.dart';
import 'cloud_vision_ocr.dart';
import 'design.dart';
import 'ocr_config.dart';
import 'ocr_service.dart';
import 'main.dart';

const double _kGapThreshold = 100;

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  _PermState _permState = _PermState.checking;
  bool _isCapturing = false;

  bool _handleKey(KeyEvent event) {
    if (_isCapturing) return false;
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.audioVolumeUp ||
         event.logicalKey == LogicalKeyboardKey.audioVolumeDown)) {
      _capture();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleKey);
    _checkPermission();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _permState == _PermState.denied) {
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
      ResolutionPreset.max,
      enableAudio: false,
    );
    await controller.initialize();
    if (!mounted) return;
    _controller = controller;
    setState(() {});
  }

  Future<OcrResult> _runOcr(String path) async {
    if (kCloudVisionApiKey.isNotEmpty) {
      try {
        return await CloudVisionOcr(apiKey: kCloudVisionApiKey).recognize(path);
      } catch (e) {
        debugPrint('[CameraScreen] cloud OCR failed, using on-device: $e');
      }
    }
    return OcrService().recognize(path);
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;

    final frac = visibleCropFractions(
      screenAspect: MediaQuery.of(context).size.aspectRatio,
      previewAspect: controller.value.aspectRatio,
    );
    setState(() => _isCapturing = true);

    try {
      await controller.setFlashMode(FlashMode.torch);
      final XFile imageFile = await controller.takePicture();
      await controller.setFlashMode(FlashMode.off);

      final scanPath = await cropToVisibleRegion(imageFile.path, frac.w, frac.h);
      final ocr = await _runOcr(scanPath);
      await File(imageFile.path).delete();
      if (scanPath != imageFile.path) await File(scanPath).delete();

      if (ocr.words.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No text detected — try better lighting or hold steadier')),
        );
        return;
      }

      final scanner = BookScanner();
      final resultsFuture = scanner.scanBooks(
        ocr.words,
        gapThreshold: _kGapThreshold,
        statusSource: const MockLibraryStatusSource(),
      );

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookResultsScreen(resultsFuture: resultsFuture),
        ),
      );
    } catch (e) {
      await _controller?.setFlashMode(FlashMode.off);
      debugPrint('[CameraScreen] capture error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_permState == _PermState.checking) {
      return Scaffold(
        backgroundColor: kBgDark,
        body: const Center(child: CircularProgressIndicator(color: kGold)),
      );
    }
    if (_permState == _PermState.denied) {
      return const _PermissionDeniedView();
    }

    final controller = _controller;
    return Scaffold(
      backgroundColor: kBgDark,
      body: SizedBox.expand(
        child: Stack(
          children: [
            // ── Camera preview ───────────────────────────────────────────────
            if (controller != null && controller.value.isInitialized)
              _CameraFramePreview(controller: controller)
            else
              const Center(child: CircularProgressIndicator(color: kGold)),

            // ── Guide frame overlay ──────────────────────────────────────────
            const _GuideOverlay(),

            // ── Instruction text ─────────────────────────────────────────────
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Fill the frame with one row of spines',
                  style: kLabel(12, color: const Color(0xFFCFC7BB)),
                ),
              ),
            ),

            // ── Shutter button ────────────────────────────────────────────────
            Positioned(
              bottom: 22,
              left: 0,
              right: 0,
              child: Center(
                child: _ShutterButton(isCapturing: _isCapturing, onTap: _capture),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

enum _PermState { checking, granted, denied }

// Guide frame: darkened vignette outside the scan rectangle + gold border.
class _GuideOverlay extends StatelessWidget {
  const _GuideOverlay();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        // Match design proportions: 60/916 left-right, 78/424 top, 112/424 bottom
        final left   = w * 0.065;
        final top    = h * 0.185;
        final right  = w * 0.065;
        final bottom = h * 0.265;
        return CustomPaint(
          size: Size(w, h),
          painter: _GuidePainter(left: left, top: top, right: right, bottom: bottom),
        );
      },
    );
  }
}

class _GuidePainter extends CustomPainter {
  final double left, top, right, bottom;
  const _GuidePainter({required this.left, required this.top, required this.right, required this.bottom});

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final inner = Path()..addRect(
        Rect.fromLTRB(left, top, size.width - right, size.height - bottom));
    final vignette = Path.combine(PathOperation.difference, outer, inner);

    canvas.drawPath(vignette, Paint()..color = const Color(0x66100F0E));

    canvas.drawRect(
      Rect.fromLTRB(left, top, size.width - right, size.height - bottom),
      Paint()
        ..color = const Color(0x80B68235)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(covariant _GuidePainter old) =>
      old.left != left || old.top != top || old.right != right || old.bottom != bottom;
}

// Full-bleed camera preview — matches what gets scanned.
class _CameraFramePreview extends StatelessWidget {
  final CameraController controller;
  const _CameraFramePreview({required this.controller});

  @override
  Widget build(BuildContext context) {
    final screenAR = MediaQuery.of(context).size.aspectRatio;
    var scale = screenAR / controller.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;
    return ClipRect(
      child: Transform.scale(
        scale: scale,
        child: Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: CameraPreview(controller),
          ),
        ),
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
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isCapturing ? const Color(0xFFCCC8C2) : const Color(0xFFF3F2F2),
          border: Border.all(color: const Color(0x80FFFFFF), width: 3),
        ),
        child: isCapturing
            ? const Padding(
                padding: EdgeInsets.all(17),
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8D857A)),
              )
            : null,
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgDark,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Camera access required', style: kHeading(22, color: const Color(0xFFEFE9E0))),
            const SizedBox(height: 10),
            Text(
              'ShelfScan needs the camera to read book spines.',
              style: kBody(13, color: const Color(0xFF8D857A)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: openAppSettings,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: kGold),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Open Settings', style: kLabel(13, color: kGoldText)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
