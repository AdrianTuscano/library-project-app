import 'package:flutter/services.dart';
import 'package:volume_controller/volume_controller.dart';
import 'nav.dart';

// ─────────────────────────────────────────────────────────────────────────────
// VolumeShutterService — single owner of the physical volume-button listener.
//
// Behaviour:
//   • If any screen is on top of the camera → pop it (back to viewfinder)
//   • If the camera is the root (nothing to pop) → call _rootAction (capture)
//
// This prevents the old bug where CameraScreen's listener stayed alive while
// results/sort screens were on top, causing stacked captures on every press.
// ─────────────────────────────────────────────────────────────────────────────

class VolumeShutterService {
  VolumeShutterService._();
  static final instance = VolumeShutterService._();

  VoidCallback? _rootAction;
  double _savedVolume = 0.5;
  bool _resetting = false;
  bool _debounce = false;

  void init() {
    VolumeController().getVolume().then((v) => _savedVolume = v);
    VolumeController().showSystemUI = false;
    VolumeController().listener(_onVolumeChange);
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  /// Called by CameraScreen to register the capture action.
  void setRootAction(VoidCallback action) => _rootAction = action;
  void clearRootAction() => _rootAction = null;

  void _onVolumeChange(double _) {
    if (_resetting || _debounce) return;
    _debounce = true;
    _resetting = true;
    VolumeController().setVolume(_savedVolume);
    Future.delayed(const Duration(milliseconds: 400), () {
      _resetting = false;
      _debounce = false;
    });
    _trigger();
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.audioVolumeUp ||
         event.logicalKey == LogicalKeyboardKey.audioVolumeDown)) {
      _trigger();
      return true;
    }
    return false;
  }

  void _trigger() {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    if (nav.canPop()) {
      nav.pop();
    } else {
      _rootAction?.call();
    }
  }
}
