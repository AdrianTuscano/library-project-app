import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'settings.dart';
import 'settings_screen.dart';
import 'widgets.dart';

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
  // Only used to decode barcodes from a still photo; never starts its own
  // camera, so there's no live per-frame analysis and no camera swap.
  final _barcodeDecoder = MobileScannerController(autoStart: false);
  _PermState _permState = _PermState.checking;
  String? _cameraError;
  bool _isCapturing = false;
  _ScanMode _mode = _ScanMode.shelf;

  // Zoom is labelled the way a phone camera labels it: 0.5x is the ultra-wide
  // lens's own field of view, 1x matches what the normal lens sees, 2x is
  // twice that. The driver's raw videoZoomFactor always starts at 1.0 on
  // whichever lens is open, so on the ultra-wide one displayed "x" is two raw
  // units — hence [_rawPerZoom].
  //
  // It stays on one lens on purpose. Seamless lens handoff needs AVFoundation's
  // virtual devices (builtInDualWideCamera), which this plugin never opens
  // (flutter/flutter#193230), so swapping lenses would mean rebuilding the
  // capture session mid-pinch — the exact stutter we're avoiding.
  static const _zoomPresets = [0.5, 1.0, 2.0];
  double _zoom = 1;
  double _rawPerZoom = 1;
  double _zoomMin = 1;
  double _zoomMax = 1;
  double _zoomAtGestureStart = 1;
  double? _pendingRawZoom;
  bool _zoomBusy = false;

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
    _barcodeDecoder.dispose().ignore();
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

  /// The widest back lens available — ultra-wide where the phone has one, so
  /// a whole shelf row fits without backing away. Pinch zoom covers closer
  /// framing from there, so the lens never has to change.
  CameraDescription _widestBackLens() {
    final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back);
    return back.where((c) => c.lensType == CameraLensType.ultraWide).firstOrNull ??
        back.where((c) => c.lensType == CameraLensType.wide).firstOrNull ??
        back.firstOrNull ??
        cameras.first;
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) {
      setState(() => _cameraError = 'No camera found on this device');
      return;
    }
    try {
      final lens = _widestBackLens();
      final controller = CameraController(
        lens,
        // 1080p is ample: Claude reads at most ~1568px, and smaller photos
        // capture, crop and upload much faster than full sensor resolution.
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      final rawMin = await controller.getMinZoomLevel();
      final rawMax = await controller.getMaxZoomLevel();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // Ultra-wide: raw 1.0 is the 0.5x view, raw 2.0 matches the normal lens.
      // Anything else is already the normal lens, so raw and displayed agree.
      final rawPerZoom = lens.lensType == CameraLensType.ultraWide ? 2.0 : 1.0;
      _controller = controller;
      setState(() {
        _rawPerZoom = rawPerZoom;
        _zoomMin = math.max(rawMin / rawPerZoom, _zoomPresets.first);
        // Capped at 2x: past that it's just a crop of the same pixels, and
        // OCR gets nothing from upscaled mush.
        _zoomMax = math.min(rawMax / rawPerZoom, _zoomPresets.last);
        // Open at the widest: it's both the most shelf in frame and the
        // sharpest, since it's the one setting that isn't a digital crop.
        _zoom = _zoomMin;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = 'Camera unavailable: $e');
    }
  }

  void _switchMode(_ScanMode mode) {
    if (_mode == mode || _isCapturing || !TapCooldown.allow()) return;
    tapFeedback();
    setState(() => _mode = mode);
  }

  bool get _canZoom => _zoomMax > _zoomMin + 0.01;

  List<double> get _availablePresets => _zoomPresets
      .where((p) => p >= _zoomMin - 0.01 && p <= _zoomMax + 0.01)
      .toList();

  /// Sets the zoom and keeps the preview tracking the finger. Requests are
  /// coalesced, not dropped: while one `setZoomLevel` is in flight the newest
  /// target replaces any older pending one, so a fast pinch ends up exactly
  /// where the finger is instead of lagging a few frames behind it.
  Future<void> _applyZoom(double zoom) async {
    if (!_canZoom) return;
    final next = zoom.clamp(_zoomMin, _zoomMax);
    if (mounted && (next - _zoom).abs() > 0.001) setState(() => _zoom = next);
    _pendingRawZoom = next * _rawPerZoom;
    if (_zoomBusy) return;
    _zoomBusy = true;
    try {
      while (_pendingRawZoom != null) {
        final target = _pendingRawZoom!;
        _pendingRawZoom = null;
        try {
          await _controller?.setZoomLevel(target);
        } catch (e) {
          debugPrint('[CameraScreen] zoom to ${target}x raw failed: $e');
        }
      }
    } finally {
      _zoomBusy = false;
    }
  }

  // Each shelf photo costs an AI read plus a catalog lookup per book, so the
  // shutter rests briefly after every capture.
  static const _shutterCooldown = Duration(seconds: 2);
  DateTime _shutterReadyAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _onShutter() async {
    if (_isCapturing || DateTime.now().isBefore(_shutterReadyAt)) return;
    if (_mode == _ScanMode.book) {
      _shutterReadyAt = DateTime.now().add(_shutterCooldown);
      return _captureBarcode();
    }
    // App Store 5.1.2(i): ask before the first photo goes to a third-party AI.
    if (kAnthropicApiKey.isNotEmpty && appSettings.aiConsent == null) {
      final allowed = await showAiConsentSheet(context);
      if (allowed == null || !mounted) return;
      appSettings.update(aiConsent: allowed);
    }
    _shutterReadyAt = DateTime.now().add(_shutterCooldown);
    return _captureShelf();
  }

  Future<void> _captureShelf() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;

    final size = MediaQuery.sizeOf(context);
    final region = _photoRegion(
      _guideFrame(size, MediaQuery.paddingOf(context), size.width > size.height, appSettings.showTips),
      size,
      controller,
    );
    tapFeedback(strong: true);
    setState(() => _isCapturing = true);

    try {
      final useLight = appSettings.useFlash;
      if (useLight) await controller.setFlashMode(FlashMode.torch);
      final photo = await controller.takePicture();
      if (useLight) await controller.setFlashMode(FlashMode.off);

      final jpeg = await prepareScanImage(photo.path, region);
      File(photo.path).delete().ignore();
      final scanFuture = await _buildScanFuture(jpeg);
      if (scanFuture == null || !mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookResultsScreen(resultsFuture: scanFuture)),
      );
    } catch (e) {
      try { await controller.setFlashMode(FlashMode.off); } catch (_) {}
      debugPrint('[CameraScreen] capture error: $e');
      _showMessage('The photo did not work. Please try again.');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  /// Maps the on-screen guide box to normalized coordinates in the upright
  /// photo. The preview is drawn with BoxFit.cover, so only the centre
  /// [visibleW]×[visibleH] of the photo is on screen.
  Rect _photoRegion(Rect frame, Size screen, CameraController controller) {
    final previewAspect = _displayAspect(context, controller);
    final screenAspect = screen.aspectRatio;
    final (visibleW, visibleH) = screenAspect >= previewAspect
        ? (1.0, previewAspect / screenAspect)
        : (screenAspect / previewAspect, 1.0);
    final region = Rect.fromLTRB(
      (1 - visibleW) / 2 + frame.left / screen.width * visibleW,
      (1 - visibleH) / 2 + frame.top / screen.height * visibleH,
      (1 - visibleW) / 2 + frame.right / screen.width * visibleW,
      (1 - visibleH) / 2 + frame.bottom / screen.height * visibleH,
    );
    // Face ID iPhones never turn the UI upside down, but the photo is still
    // saved upright, so the box lands rotated 180° within it.
    if (controller.value.deviceOrientation == DeviceOrientation.portraitDown) {
      return Rect.fromLTRB(1 - region.right, 1 - region.bottom, 1 - region.left, 1 - region.top);
    }
    return region;
  }

  Future<void> _captureBarcode() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;
    tapFeedback(strong: true);
    setState(() => _isCapturing = true);

    String? photoPath;
    try {
      final photo = await controller.takePicture();
      photoPath = photo.path;
      final capture = await _barcodeDecoder.analyzeImage(photo.path);
      final rawValues = (capture?.barcodes ?? const []).map((b) => b.rawValue).toList();
      debugPrint('[CameraScreen] decoded barcodes: $rawValues');
      final isbn = _pickIsbn(capture?.barcodes ?? const []);
      debugPrint('[CameraScreen] picked ISBN: $isbn');
      if (!mounted) return;
      if (isbn == null) {
        _showMessage('No book barcode found. Move closer and try again.');
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookScanScreen(isbn: isbn)),
      );
    } catch (e) {
      debugPrint('[CameraScreen] barcode error: $e');
      _showMessage('The photo did not work. Please try again.');
    } finally {
      if (photoPath != null) File(photoPath).delete().ignore();
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  /// Prefers an ISBN-13 (978/979 "Bookland" EAN) over other barcodes on the
  /// cover, such as the 5-digit price add-on or a library item sticker.
  static String? _pickIsbn(List<Barcode> barcodes) {
    final values = barcodes
        .map((b) => (b.rawValue ?? '').replaceAll(RegExp(r'[^0-9Xx]'), ''))
        .where((v) => v.isNotEmpty)
        .toList();
    return values.where((v) => RegExp(r'^97[89]\d{10}$').hasMatch(v)).firstOrNull ??
        values.where((v) => RegExp(r'^\d{9}[\dXx]$').hasMatch(v)).firstOrNull;
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<Future<ScanResult>?> _buildScanFuture(Uint8List jpeg) async {
    if (kAnthropicApiKey.isNotEmpty && appSettings.aiConsent == true) {
      return const ClaudeOcr(apiKey: kAnthropicApiKey).scan(jpeg);
    }
    // The on-device OCR fallbacks read from a file.
    final file = File('${Directory.systemTemp.path}/shelf_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(jpeg);
    final OcrResult ocr;
    try {
      ocr = await _ocrFallback(file.path);
    } finally {
      file.delete().ignore();
    }
    if (ocr.words.isEmpty) {
      _showMessage('No words found. Try more light, and hold the phone still.');
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

  Future<void> _openSettings() async {
    if (!TapCooldown.allow()) return;
    tapFeedback();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    if (mounted) setState(() {});
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

    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final landscape = size.width > size.height;
    final tips = appSettings.showTips;
    final controller = _controller;
    final frame = _guideFrame(size, pad, landscape, tips);

    return Scaffold(
      backgroundColor: kBgDark,
      // Pinch anywhere over the preview to zoom, like the stock camera. Taps
      // on the controls above still reach them — only scale gestures land here.
      body: GestureDetector(
        onScaleStart: (_) => _zoomAtGestureStart = _zoom,
        onScaleUpdate: (d) => _applyZoom(_zoomAtGestureStart * d.scale),
        child: Stack(
        children: [
          if (controller != null && controller.value.isInitialized)
            _CameraFramePreview(controller: controller)
          else
            const Center(child: CircularProgressIndicator(color: kGold)),
          CustomPaint(size: size, painter: _GuidePainter(frame: frame)),
          // Settings: top-right corner, anchored by `top`+`right` alone so it
          // sits in the corner rather than being laid out next to anything.
          Positioned(
            top: _inset(pad.top),
            right: _inset(pad.right),
            child: _SettingsButton(onTap: _openSettings),
          ),
          // Hint: sits directly above the viewfinder, tracking the frame
          // itself rather than a screen edge, in both orientations.
          if (tips)
            Positioned(
              left: 24,
              right: 24,
              bottom: size.height - frame.top + 10,
              child: Center(child: _TipPill(mode: _mode)),
            ),
          // Shutter: bottom-centre, in both orientations.
          Positioned(
            left: 0,
            right: 0,
            bottom: _inset(pad.bottom),
            child: Center(child: _shutter()),
          ),
          // Mode toggle: directly above the capture button in portrait,
          // bottom-right corner in landscape.
          if (landscape)
            Positioned(
              right: _inset(pad.right),
              bottom: _inset(pad.bottom),
              child: _ModeToggle(current: _mode, onSwitch: _switchMode),
            )
          else
            Positioned(
              left: 0,
              right: 0,
              bottom: _inset(pad.bottom) + _shutterSize + _controlGap,
              child: Center(child: _ModeToggle(current: _mode, onSwitch: _switchMode)),
            ),
          // Zoom: bottom-left, the one corner free in both orientations.
          if (_canZoom)
            Positioned(
              left: _inset(pad.left),
              bottom: _inset(pad.bottom),
              child: _ZoomControl(
                zoom: _zoom,
                presets: _availablePresets,
                onSelect: (z) {
                  tapFeedback();
                  _applyZoom(z);
                },
              ),
            ),
        ],
        ),
      ),
    );
  }

  Widget _shutter() => _ShutterButton(
        busy: _isCapturing,
        label: _mode == _ScanMode.shelf ? 'Take a photo of the shelf' : 'Scan the barcode',
        onTap: _onShutter,
      );

  static const _shutterSize = 60.0;
  static const _settingsSize = 52.0;
  static const _tipHeight = 64.0;
  static const _toggleBand = 58.0;

  /// Every control keeps the same distance from the screen edge: the system
  /// safe area when that's larger (home indicator, notch), otherwise this.
  /// One rule instead of a different hand-picked number per control.
  static const _edgeInset = 12.0;
  /// Gap between two stacked controls.
  static const _controlGap = 12.0;

  static double _inset(double safeArea) => math.max(safeArea, _edgeInset);

  /// Shelf box shape, per orientation. Landscape runs wider: that box is
  /// limited by height, so a wider ratio spends the leftover width rather
  /// than shrinking the box.
  static const _shelfAspect = 3.2;
  static const _shelfAspectPortrait = 2.4;
  static const _barcodeAspect = 2.0;

  /// The box is a drawn outline, not something you tap, so it may sit closer
  /// to the screen edge than the controls are allowed to.
  static const _frameInset = 4.0;

  /// The guide box, centred on the screen. Its size is limited by the space
  /// the controls take, applied to both sides so it stays centred.
  Rect _guideFrame(Size size, EdgeInsets pad, bool landscape, bool tips) {
    final center = size.center(Offset.zero);
    // The settings button sits in the top-right corner and the hint sits
    // centred above the box — side by side, not stacked — so the strip only
    // needs to be as tall as the taller of the two, not their sum.
    final top = _inset(pad.top) +
        math.max(_settingsSize, tips ? _tipHeight : 0) +
        _controlGap;
    // Shutter, plus the toggle where it stacks above it (portrait only — in
    // landscape the toggle sits beside the shutter, sharing the same band).
    final bottom = _inset(pad.bottom) +
        _shutterSize +
        _controlGap +
        (landscape ? 0 : _toggleBand);
    // Only the notch/home-indicator insets hold the box back horizontally —
    // it may run right out to the edge otherwise.
    final side = math.max(math.max(pad.left, pad.right), _frameInset);
    final maxW = math.max(0.0, size.width - side * 2);
    final maxH = math.max(
      0.0,
      2 * math.min(center.dy - top, size.height - bottom - center.dy),
    );

    final shelf = _mode == _ScanMode.shelf;
    final aspect = shelf
        ? (landscape ? _shelfAspect : _shelfAspectPortrait)
        : _barcodeAspect;
    final w = math.min(maxW * (shelf ? 1 : 0.75), maxH * aspect);
    return Rect.fromCenter(center: center, width: w, height: w / aspect);
  }
}


/// The preview's aspect ratio as drawn on screen. The camera reports it in
/// landscape terms, so it flips when the phone is upright.
double _displayAspect(BuildContext context, CameraController controller) {
  final ar = controller.value.aspectRatio;
  return isLandscape(context) ? ar : 1 / ar;
}

class _GuidePainter extends CustomPainter {
  final Rect frame;
  const _GuidePainter({required this.frame});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(frame, const Radius.circular(14));
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()..addRRect(rrect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = kBgDark.withValues(alpha: 0.5),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = kGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _GuidePainter old) => old.frame != frame;
}

class _CameraFramePreview extends StatelessWidget {
  final CameraController controller;
  const _CameraFramePreview({required this.controller});

  @override
  Widget build(BuildContext context) {
    final ar = _displayAspect(context, controller);
    // Fill the screen, cropping the edges (matches cropToVisibleRegion).
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: 1000 * ar,
          height: 1000,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

const _overlayBg = Color(0xD91A1917);

class _SettingsButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SettingsButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Settings',
      excludeSemantics: true,
      child: Material(
        color: _overlayBg,
        shape: const CircleBorder(side: BorderSide(color: Color(0x40FFFFFF))),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const SizedBox(
            width: 52,
            height: 52,
            child: Icon(Icons.settings_rounded, color: kOnDark, size: 28),
          ),
        ),
      ),
    );
  }
}

/// Zoom steps, the way a phone camera shows them: one tap per preset, and the
/// selected one carries the live value while pinching (so 1x reads "1.4x" on
/// the way to 2x) instead of a separate readout appearing somewhere else.
class _ZoomControl extends StatelessWidget {
  final double zoom;
  final List<double> presets;
  final ValueChanged<double> onSelect;
  const _ZoomControl({required this.zoom, required this.presets, required this.onSelect});

  /// The step the current zoom belongs to: the largest preset at or below it.
  double get _active =>
      presets.lastWhere((p) => zoom >= p - 0.01, orElse: () => presets.first);

  static String _label(double v) {
    final oneDecimal = v.toStringAsFixed(1);
    return oneDecimal.endsWith('.0') ? '${v.toStringAsFixed(0)}x' : '${oneDecimal}x';
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    // Fixed size: this is a dense numeric control, so it reads the phone's
    // text-size setting out rather than overflowing at the largest steps.
    return MediaQuery.withNoTextScaling(
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: _overlayBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x40FFFFFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final preset in presets) ...[
              if (preset != presets.first) const SizedBox(width: 2),
              _ZoomStep(
                label: preset == active ? _label(zoom) : _label(preset),
                active: preset == active,
                onTap: () => onSelect(preset),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ZoomStep extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ZoomStep({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: 'Zoom $label',
      excludeSemantics: true,
      child: Material(
        color: active ? kGold : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40, minWidth: 42),
            child: Center(
              child: Text(
                label,
                style: kLabel(14,
                    color: active ? const Color(0xFF1A1917) : kOnDark,
                    weight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TipPill extends StatelessWidget {
  final _ScanMode mode;
  const _TipPill({required this.mode});

  @override
  Widget build(BuildContext context) {
    final text = mode == _ScanMode.shelf
        ? 'Fit one row of books inside the box'
        : 'Fit the barcode inside the box';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _overlayBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: kLabel(17, color: kOnDark),
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
    );
  }
}

/// Plain white shutter — a single flat disc, no outer ring.
class _ShutterButton extends StatelessWidget {
  final bool busy;
  final String label;
  final VoidCallback onTap;
  const _ShutterButton({required this.busy, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !busy,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: _CameraScreenState._shutterSize,
          height: _CameraScreenState._shutterSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: busy ? const Color(0xFFBDB8B1) : Colors.white,
          ),
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(strokeWidth: 3, color: kGoldText),
                )
              : null,
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final _ScanMode current;
  final void Function(_ScanMode) onSwitch;
  const _ModeToggle({required this.current, required this.onSwitch});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _overlayBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x40FFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeOption(
            label: 'Shelf',
            active: current == _ScanMode.shelf,
            onTap: () => onSwitch(_ScanMode.shelf),
          ),
          const SizedBox(width: 4),
          _ModeOption(
            label: 'ISBN',
            active: current == _ScanMode.book,
            onTap: () => onSwitch(_ScanMode.book),
          ),
        ],
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ModeOption({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = active ? const Color(0xFF1A1917) : kOnDark;
    return Semantics(
      button: true,
      selected: active,
      label: 'Scan mode: $label',
      excludeSemantics: true,
      child: Material(
        color: active ? kGold : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTap),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Center(
                widthFactor: 1,
                child: Text(label,
                    style: kLabel(17, color: fg, weight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
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

class _DarkMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const _DarkMessage({required this.icon, required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBgDark,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: kGold, size: 56),
                    const SizedBox(height: 16),
                    Text(title,
                        textAlign: TextAlign.center,
                        style: kHeading(28, color: kOnDark)),
                    const SizedBox(height: 10),
                    Text(message,
                        textAlign: TextAlign.center,
                        style: kBody(17, color: kOnDarkMut)),
                    if (action != null) ...[const SizedBox(height: 28), action!],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _CameraErrorView extends StatelessWidget {
  final String message;
  const _CameraErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    debugPrint('[CameraScreen] $message');
    return const _DarkMessage(
      icon: Icons.no_photography_rounded,
      title: 'The camera is not working',
      message: 'Close ShelfScan and open it again. If that does not help, restart your phone.',
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView();

  @override
  Widget build(BuildContext context) => const _DarkMessage(
        icon: Icons.photo_camera_rounded,
        title: 'ShelfScan needs your camera',
        message: 'The camera reads the book spines. Turn on Camera for ShelfScan in Settings.',
        action: AppButton(
          label: 'Open Settings',
          icon: Icons.settings_rounded,
          onDark: true,
          onPressed: openAppSettings,
        ),
      );
}
