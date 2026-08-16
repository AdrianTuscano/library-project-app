import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_gripper_service.dart';
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

const double _kGapThreshold = 100; // only used by fallback OCR path

enum _ScanMode { shelf, book }

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
  bool _showGripperPanel = false;
  _ScanMode _mode = _ScanMode.shelf;

  // Volume button and selfie-stick shutter are handled by VolumeShutterService
  // (a singleton that lives for the app lifetime). CameraScreen only registers
  // its capture action as the "root" handler — the service decides whether to
  // pop a screen or capture based on the current navigator state.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VolumeShutterService.instance.setRootAction(_capture);
    _checkPermission();
  }

  // ── Mode switching ────────────────────────────────────────────────────────

  Future<void> _switchMode(_ScanMode mode) async {
    if (_mode == mode || _isSwitchingMode || _isCapturing) return;
    _isSwitchingMode = true;
    try {
    if (mode == _ScanMode.book) {
      // Hand camera to MobileScanner — dispose CameraController first.
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

  Future<void> _capture() async {
    if (!mounted) return;
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

      Future<ScanResult> resultsFuture;

      if (kAnthropicApiKey.isNotEmpty) {
        // Claude end-to-end: identifies books directly from the photo.
        // No Open Library / Google Books needed.
        resultsFuture = ClaudeOcr(apiKey: kAnthropicApiKey).scan(scanPath);
      } else {
        // Fallback: Cloud Vision or on-device OCR → Open Library lookup.
        final ocr = await _runFallbackOcr(scanPath);
        if (ocr.words.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No text detected — try better lighting or hold steadier')),
          );
          return;
        }
        resultsFuture = BookScanner().scanBooks(
          ocr.words,
          gapThreshold: _kGapThreshold,
          statusSource: const MockLibraryStatusSource(),
        );
      }

      // Clean up temp files after kicking off the future (not blocking nav).
      resultsFuture.whenComplete(() {
        File(imageFile.path).delete().ignore();
        if (scanPath != imageFile.path) File(scanPath).delete().ignore();
      });

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookResultsScreen(resultsFuture: resultsFuture),
        ),
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

  /// Fallback OCR when no Anthropic key is set (Cloud Vision → on-device ML Kit).
  Future<OcrResult> _runFallbackOcr(String path) async {
    if (kCloudVisionApiKey.isNotEmpty) {
      try {
        return await CloudVisionOcr(apiKey: kCloudVisionApiKey).recognize(path);
      } catch (e) {
        debugPrint('[CameraScreen] Cloud Vision failed, using on-device: $e');
      }
    }
    return OcrService().recognize(path);
  }

  @override
  Widget build(BuildContext context) {
    if (_permState == _PermState.checking) {
      return const Scaffold(
        backgroundColor: kBgDark,
        body: Center(child: CircularProgressIndicator(color: kGold)),
      );
    }
    if (_permState == _PermState.denied) {
      return const _PermissionDeniedView();
    }
    if (_cameraError != null) {
      return Scaffold(
        backgroundColor: kBgDark,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Camera error', style: kHeading(22, color: const Color(0xFFEFE9E0))),
              const SizedBox(height: 10),
              Text(_cameraError!, style: kBody(13, color: const Color(0xFF8D857A)),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    // Show rotate prompt if the phone hasn't gone landscape yet.
    final size = MediaQuery.of(context).size;
    if (size.width < size.height) {
      return Scaffold(
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

    final pad = MediaQuery.of(context).padding;
    final controller = _controller;

    return Scaffold(
      backgroundColor: kBgDark,
      body: SizedBox.expand(
        child: Stack(
          children: [
            // ── Camera / barcode feed ────────────────────────────────────────
            if (_mode == _ScanMode.shelf) ...[
              if (controller != null && controller.value.isInitialized)
                _CameraFramePreview(controller: controller)
              else
                const Center(child: CircularProgressIndicator(color: kGold)),
              const _GuideOverlay(mode: _ScanMode.shelf),
            ] else ...[
              if (_barcodeController != null)
                MobileScanner(
                  controller: _barcodeController!,
                  onDetect: _onBarcodeDetected,
                )
              else
                const Center(child: CircularProgressIndicator(color: kGold)),
              const _GuideOverlay(mode: _ScanMode.book),
            ],

            // ── Instruction text ─────────────────────────────────────────────
            Positioned(
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
            ),

            // ── Shutter button (shelf mode only) ─────────────────────────────
            if (_mode == _ScanMode.shelf)
              Positioned(
                bottom: pad.bottom + 16,
                left: 0,
                right: 0,
                child: Center(
                  child: _ShutterButton(
                      isCapturing: _isCapturing, onTap: _capture),
                ),
              ),

            // ── Mode switcher pill ────────────────────────────────────────────
            Positioned(
              bottom: pad.bottom + 14,
              right: 28,
              child: _ModeSwitcher(
                current: _mode,
                onSwitch: _switchMode,
              ),
            ),

            // ── Gripper panel (expands above button) ─────────────────────────
            if (_showGripperPanel)
              Positioned(
                bottom: pad.bottom + 60,
                left: 20,
                child: _GripperPanel(
                  onClose: () => setState(() => _showGripperPanel = false),
                ),
              ),

            // ── BLE gripper button ────────────────────────────────────────────
            Positioned(
              bottom: pad.bottom + 14,
              left: 20,
              child: _GripperButton(
                panelOpen: _showGripperPanel,
                onTap: () => setState(() => _showGripperPanel = !_showGripperPanel),
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
  final _ScanMode mode;
  const _GuideOverlay({required this.mode});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        final double left, top, right, bottom;

        if (mode == _ScanMode.shelf) {
          // Wide landscape strip — full row of spines
          left   = w * 0.065;
          top    = h * 0.185;
          right  = w * 0.065;
          bottom = h * 0.265;
        } else {
          // Wide short rectangle — ISBN / EAN-13 barcode in landscape
          left   = w * 0.15;
          top    = h * 0.30;
          right  = w * 0.15;
          bottom = h * 0.30;
        }

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

    canvas.drawPath(vignette, Paint()..color = kBgDark.withValues(alpha: 0.4));

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

// Mode switcher pill — lives in the bottom-right corner of the camera view.
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

// ── BLE Gripper ───────────────────────────────────────────────────────────────

class _GripperButton extends StatelessWidget {
  final bool panelOpen;
  final VoidCallback onTap;
  const _GripperButton({required this.panelOpen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BleGripperService.instance,
      builder: (context, _) {
        final svc = BleGripperService.instance;
        final Color dotColor;
        switch (svc.state) {
          case GripperState.connected:
            dotColor = const Color(0xFF6FCF97);
          case GripperState.scanning:
          case GripperState.connecting:
            dotColor = kGold;
          case GripperState.disconnected:
            dotColor = const Color(0xFF6B6560);
        }

        return GestureDetector(
          onTap: onTap,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: panelOpen ? const Color(0xEE1A1917) : const Color(0xBB1A1917),
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: panelOpen
                    ? const Color(0x66FFFFFF)
                    : const Color(0x33FFFFFF),
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bluetooth, size: 14, color: dotColor),
                const SizedBox(width: 5),
                Text('GRIPPER', style: kLabel(11, color: const Color(0xFFBBB5AD), tracking: 0.08)),
                const SizedBox(width: 6),
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GripperPanel extends StatelessWidget {
  final VoidCallback onClose;
  const _GripperPanel({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BleGripperService.instance,
      builder: (context, _) {
        final svc = BleGripperService.instance;
        return Container(
          width: 240,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xF01A1917),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ──────────────────────────────────────────────────────
              Row(
                children: [
                  Text('Book Gripper', style: kHeading(15, color: const Color(0xFFEFE9E0))),
                  const Spacer(),
                  GestureDetector(
                    onTap: onClose,
                    child: const Icon(Icons.close, size: 16, color: Color(0xFF8D857A)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(_statusLabel(svc.state),
                  style: kBody(11, color: const Color(0xFF8D857A))),
              const SizedBox(height: 14),

              if (svc.state == GripperState.disconnected) ...[
                // ── Connect button ─────────────────────────────────────────
                _PanelButton(
                  label: 'Connect',
                  color: kGold,
                  textColor: const Color(0xFF1A1917),
                  onTap: BleGripperService.instance.connect,
                ),
                if (svc.error != null) ...[
                  const SizedBox(height: 8),
                  Text(svc.error!, style: kBody(10, color: const Color(0xFFE07070)),
                      maxLines: 2),
                ],
              ] else if (svc.state == GripperState.scanning ||
                         svc.state == GripperState.connecting) ...[
                // ── Scanning / connecting ──────────────────────────────────
                const Center(
                  child: SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kGold),
                  ),
                ),
              ] else ...[
                // ── Connected controls ─────────────────────────────────────
                Text('Grip', style: kLabel(11, color: const Color(0xFF8D857A), tracking: 0.06)),
                const SizedBox(height: 4),
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    activeTrackColor: kGold,
                    inactiveTrackColor: const Color(0xFF3A3835),
                    thumbColor: const Color(0xFFEFE9E0),
                    overlayColor: kGold.withValues(alpha: 0.15),
                  ),
                  child: Slider(
                    value: svc.position,
                    onChanged: svc.moving ? null : (v) => svc.moveTo(v),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _PanelButton(
                        label: 'Open',
                        color: const Color(0xFF2A2925),
                        textColor: const Color(0xFFEFE9E0),
                        onTap: svc.moving ? null : svc.openFull,
                        icon: Icons.open_in_full,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _PanelButton(
                        label: 'Close',
                        color: kGold,
                        textColor: const Color(0xFF1A1917),
                        onTap: svc.moving ? null : svc.closeFull,
                        icon: Icons.close_fullscreen,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _PanelButton(
                        label: 'Stop',
                        color: const Color(0xFF2A2925),
                        textColor: const Color(0xFFEFE9E0),
                        onTap: svc.stop,
                        icon: Icons.stop,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _PanelButton(
                        label: 'Home',
                        color: const Color(0xFF2A2925),
                        textColor: const Color(0xFFEFE9E0),
                        onTap: svc.moving ? null : svc.home,
                        icon: Icons.home_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: svc.disconnect,
                  child: Center(
                    child: Text('Disconnect',
                        style: kLabel(11, color: const Color(0xFF8D857A), tracking: 0.04)),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _statusLabel(GripperState s) {
    switch (s) {
      case GripperState.disconnected: return 'Not connected';
      case GripperState.scanning:     return 'Scanning for gripper...';
      case GripperState.connecting:   return 'Connecting...';
      case GripperState.connected:    return 'Connected';
    }
  }
}

class _PanelButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback? onTap;
  final IconData? icon;
  const _PanelButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: enabled ? color : color.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: enabled ? textColor : textColor.withValues(alpha: 0.4)),
              const SizedBox(width: 4),
            ],
            Text(label,
                style: kLabel(11,
                    color: enabled ? textColor : textColor.withValues(alpha: 0.4),
                    tracking: 0.06)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

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
