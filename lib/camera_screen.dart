import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'book_results_screen.dart';
import 'book_scan_screen.dart';
import 'book_scanner.dart';
import 'claude_ocr.dart';
import 'cloud_vision_ocr.dart';
import 'design.dart';
import 'main.dart';
import 'ocr_config.dart';
import 'ocr_service.dart';
import 'volume_shutter_service.dart';

const double _fallbackGapThreshold = 100;

enum _ScanMode { shelf, book }

enum _PermState { checking, granted, denied }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  MobileScannerController? _barcodeController;
  _PermState _permState = _PermState.checking;
  String? _cameraError;
  bool _isCapturing = false;
  bool _barcodeScanned = false;
  bool _isSwitchingMode = false;
  _ScanMode _mode = _ScanMode.shelf;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VolumeShutterService.instance.setRootAction(_capture);
    _checkPermission();
  }

  @override
  void dispose() {
    VolumeShutterService.instance.clearRootAction();
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _barcodeController?.dispose();
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
    if (cameras.isEmpty) {
      setState(() => _cameraError = 'No camera found on this device');
      return;
    }
    try {
      final controller = CameraController(
        cameras[0],
        ResolutionPreset.max,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      _controller = controller;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = 'Camera unavailable: $e');
    }
  }

  Future<void> _switchMode(_ScanMode mode) async {
    if (_mode == mode || _isSwitchingMode || _isCapturing) return;
    _isSwitchingMode = true;
    try {
      if (mode == _ScanMode.book) {
        await _controller?.dispose();
        _controller = null;
        _barcodeController = MobileScannerController(
          detectionSpeed: DetectionSpeed.normal,
          facing: CameraFacing.back,
        );
      } else {
        await _barcodeController?.dispose();
        _barcodeController = null;
        await _initCamera();
      }
      if (mounted) setState(() { _mode = mode; _barcodeScanned = false; });
    } finally {
      _isSwitchingMode = false;
    }
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    if (_barcodeScanned || !mounted) return;
    final raw = capture.barcodes
        .where((b) => b.rawValue != null)
        .map((b) => b.rawValue!)
        .firstOrNull;
    if (raw == null) return;
    _barcodeScanned = true;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookScanScreen(isbn: raw)),
    ).then((_) {
      if (mounted) setState(() => _barcodeScanned = false);
    });
  }

  Future<void> _capture() async {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;

    final cropFractions = visibleCropFractions(
      screenAspect: MediaQuery.of(context).size.aspectRatio,
      previewAspect: controller.value.aspectRatio,
    );
    setState(() => _isCapturing = true);

    try {
      await controller.setFlashMode(FlashMode.torch);
      final photo = await controller.takePicture();
      await controller.setFlashMode(FlashMode.off);

      final croppedPath = await cropToVisibleRegion(photo.path, cropFractions.w, cropFractions.h);
      final scanFuture = await _buildScanFuture(croppedPath);
      if (scanFuture == null) return;

      scanFuture.whenComplete(() {
        File(photo.path).delete().ignore();
        if (croppedPath != photo.path) File(croppedPath).delete().ignore();
      });

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookResultsScreen(resultsFuture: scanFuture)),
      );
    } catch (e) {
      try { await _controller?.setFlashMode(FlashMode.off); } catch (_) {}
      debugPrint('[CameraScreen] capture error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<Future<ScanResult>?> _buildScanFuture(String imagePath) async {
    if (kAnthropicApiKey.isNotEmpty) {
      return ClaudeOcr(apiKey: kAnthropicApiKey).scan(imagePath);
    }
    final ocr = await _ocrFallback(imagePath);
    if (ocr.words.isEmpty) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No text detected — try better lighting or hold steadier')),
      );
      return null;
    }
    return BookScanner().scanBooks(
      ocr.words,
      gapThreshold: _fallbackGapThreshold,
      statusSource: const MockLibraryStatusSource(),
    );
  }

  Future<OcrResult> _ocrFallback(String imagePath) async {
    if (kCloudVisionApiKey.isNotEmpty) {
      try {
        return await CloudVisionOcr(apiKey: kCloudVisionApiKey).recognize(imagePath);
      } catch (e) {
        debugPrint('[CameraScreen] Cloud Vision failed, using on-device: $e');
      }
    }
    return OcrService().recognize(imagePath);
  }

  @override
  Widget build(BuildContext context) {
    if (_permState == _PermState.checking) {
      return const _LoadingView();
    }
    if (_permState == _PermState.denied) {
      return const _PermissionDeniedView();
    }
    if (_cameraError != null) {
      return _CameraErrorView(message: _cameraError!);
    }

    final size = MediaQuery.of(context).size;
    if (size.width < size.height) {
      return const _RotatePromptView();
    }

    final pad = MediaQuery.of(context).padding;
    final controller = _controller;

    return Scaffold(
      backgroundColor: kBgDark,
      body: SizedBox.expand(
        child: Stack(
          children: [
            _cameraFeed(controller),
            _GuideOverlay(mode: _mode),
            _instructionLabel(pad),
            if (_mode == _ScanMode.shelf) _shutterButton(pad),
            _modeSwitcher(pad),
          ],
        ),
      ),
    );
  }

  Widget _cameraFeed(CameraController? controller) {
    if (_mode == _ScanMode.shelf) {
      if (controller != null && controller.value.isInitialized) {
        return _CameraFramePreview(controller: controller);
      }
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    if (_barcodeController != null) {
      return MobileScanner(
        controller: _barcodeController!,
        onDetect: _onBarcodeDetected,
      );
    }
    return const Center(child: CircularProgressIndicator(color: kGold));
  }

  Widget _instructionLabel(EdgeInsets pad) => Positioned(
    top: pad.top + 12,
    left: 0,
    right: 0,
    child: Center(
      child: Text(
        _mode == _ScanMode.shelf
            ? 'Fill the frame with one row of spines'
            : 'Point at the ISBN barcode on the book',
        style: kLabel(12, color: const Color(0xFFCFC7BB)),
      ),
    ),
  );

  Widget _shutterButton(EdgeInsets pad) => Positioned(
    bottom: pad.bottom + 16,
    left: 0,
    right: 0,
    child: Center(
      child: _ShutterButton(isCapturing: _isCapturing, onTap: _capture),
    ),
  );

  Widget _modeSwitcher(EdgeInsets pad) => Positioned(
    bottom: pad.bottom + 14,
    right: 28,
    child: _ModeSwitcher(current: _mode, onSwitch: _switchMode),
  );
}

class _GuideOverlay extends StatelessWidget {
  final _ScanMode mode;
  const _GuideOverlay({required this.mode});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final (left, top, right, bottom) = _insets(w, h);
        return CustomPaint(
          size: Size(w, h),
          painter: _GuidePainter(left: left, top: top, right: right, bottom: bottom),
        );
      },
    );
  }

  (double, double, double, double) _insets(double w, double h) {
    if (mode == _ScanMode.shelf) {
      return (w * 0.065, h * 0.185, w * 0.065, h * 0.265);
    }
    return (w * 0.15, h * 0.30, w * 0.15, h * 0.30);
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
    final cutout = Path.combine(PathOperation.difference, outer, inner);

    canvas.drawPath(cutout, Paint()..color = kBgDark.withValues(alpha: 0.4));
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

class _ModeSwitcher extends StatelessWidget {
  final _ScanMode current;
  final void Function(_ScanMode) onSwitch;
  const _ModeSwitcher({required this.current, required this.onSwitch});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: const Color(0xBB1A1917),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Pill(label: 'SHELF', active: current == _ScanMode.shelf,
              onTap: () => onSwitch(_ScanMode.shelf)),
          _Pill(label: 'BOOK',  active: current == _ScanMode.book,
              onTap: () => onSwitch(_ScanMode.book)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Pill({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? kGold : Colors.transparent,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Text(
          label,
          style: kLabel(11,
              color: active ? const Color(0xFF1A1917) : const Color(0xFFBBB5AD),
              tracking: 0.08),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: kBgDark,
    body: Center(child: CircularProgressIndicator(color: kGold)),
  );
}

class _CameraErrorView extends StatelessWidget {
  final String message;
  const _CameraErrorView({required this.message});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBgDark,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Camera error', style: kHeading(22, color: const Color(0xFFEFE9E0))),
          const SizedBox(height: 10),
          Text(message, style: kBody(13, color: const Color(0xFF8D857A)),
              textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _RotatePromptView extends StatelessWidget {
  const _RotatePromptView();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBgDark,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.screen_rotation, color: kGold, size: 48),
          const SizedBox(height: 16),
          Text('Rotate your phone', style: kHeading(22, color: const Color(0xFFEFE9E0))),
          const SizedBox(height: 8),
          Text('ShelfScan works in landscape mode', style: kLabel(13, color: const Color(0xFF8D857A))),
        ],
      ),
    ),
  );
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
