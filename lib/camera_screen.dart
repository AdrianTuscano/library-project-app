import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'book_results_screen.dart';
import 'book_scanner.dart';
import 'cloud_vision_ocr.dart';
import 'ocr_config.dart';
import 'ocr_service.dart';
import 'main.dart';

// Gap threshold in pixels at the captured image resolution.
// 20px matched the Pi webcam at 720p. Phone cameras at veryHigh (~1920px wide)
// need ~100–150px. Raise if spines are merging; lower if one spine splits.
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
      return true; // consume — prevents volume HUD from showing
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
      ResolutionPreset.max,
      enableAudio: false,
    );
    await controller.initialize();
    if (!mounted) return;
    _controller = controller;
    setState(() {});
  }

  // Cloud Vision when a key is configured; on-device multi-orientation OCR
  // otherwise, or if the cloud call fails (e.g. offline).
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

    // Capture the visible crop up front (needs context, no awaits before it).
    final frac = visibleCropFractions(
      screenAspect: MediaQuery.of(context).size.aspectRatio,
      previewAspect: controller.value.aspectRatio,
    );
    setState(() => _isCapturing = true);

    try {
      await controller.setFlashMode(FlashMode.torch);
      final XFile imageFile = await controller.takePicture();
      await controller.setFlashMode(FlashMode.off);

      // Crop the still to exactly what the full-bleed preview showed, so we only
      // scan what was on screen (the preview covers the screen and crops the
      // overflow; mirror that crop here).
      final scanPath =
          await cropToVisibleRegion(imageFile.path, frac.w, frac.h);

      // OCR: prefer Cloud Vision, fall back to on-device (see _runOcr). Words
      // come back with centers on the original frame's X axis either way.
      final ocr = await _runOcr(scanPath);
      await File(imageFile.path).delete();
      if (scanPath != imageFile.path) {
        await File(scanPath).delete();
      }

      // No text at all — stay on camera, show a tip.
      if (ocr.words.isEmpty) {
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
          scanner.clusterByGap(ocr.words, gapThreshold: _kGapThreshold).length;
      // TESTING: cache disabled so every scan is a fresh lookup — makes it
      // possible to gauge accuracy without stale results. Pass `cache: bookCache`
      // again to re-enable instant offline repeats for demos.
      // statusSource is a mock until Georgetown PL grants access to real
      // circulation status (see LibraryStatusSource).
      final resultsFuture = scanner.scanBooks(
        ocr.words,
        gapThreshold: _kGapThreshold,
        statusSource: const MockLibraryStatusSource(),
      );

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookResultsScreen(
            resultsFuture: resultsFuture,
            words: ocr.words,
            gapThreshold: _kGapThreshold,
            clusterCount: clusterCount,
            rotationUsed: ocr.rotationUsed,
          ),
        ),
      );
    } catch (e) {
      await _controller?.setFlashMode(FlashMode.off);
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
      body: SizedBox.expand(
        child: Stack(
          children: [
            // ── Camera preview — full-bleed, fills the screen ───────────────
            // The preview covers the whole screen (no black bars). The captured
            // photo is then cropped to this same visible region before OCR (see
            // _capture), so we only ever scan what's on screen.
            if (controller != null && controller.value.isInitialized)
              _CameraFramePreview(controller: controller)
            else
              const Center(child: CircularProgressIndicator()),

            // ── Top scrim for legibility ────────────────────────────────────
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 96,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
              ),
            ),

            // ── Tip pill at top ─────────────────────────────────────────────
            const Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: _PillLabel('Fill the frame with the row of spines'),
              ),
            ),

            // ── Edge chips — mark the ends so results read left → right ──────
            // Left chip doubles as the charging-port guide (port goes on this side).
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 12),
                child: _EdgeChip(label: 'PORT', icon: Icons.bolt, accent: true),
              ),
            ),
            const Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: 12),
                child: _EdgeChip(label: 'RIGHT'),
              ),
            ),

            // ── Shutter button — bottom centre ──────────────────────────────
            Positioned(
              bottom: 28,
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

// Fills the whole screen with the preview (cover, no black bars). The captured
// still is cropped to match this visible region before OCR, so scanning stays
// WYSIWYG — see visibleCropFractions / cropToVisibleRegion.
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

// Small rounded chip pinned to a screen edge. Marks the ends of the row so the
// user knows the scan reads left → right; the left chip also flags the side the
// charging port should be on.
class _EdgeChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool accent;
  const _EdgeChip({required this.label, this.icon, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final color = accent ? const Color(0xFF4E9BFF) : Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: color),
            const SizedBox(height: 2),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
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
