import 'package:flutter/services.dart';
import 'package:volume_controller/volume_controller.dart';
import 'nav.dart';

class VolumeShutterService {
  VolumeShutterService._();
  static final instance = VolumeShutterService._();

  VoidCallback? _rootAction;
  VoidCallback? _override; // set by screens that want to claim volume keys entirely
  double _savedVolume = 0.5;
  bool _resettingVolume = false;

  void init() {
    // VolumeController throws on iOS 26 if audio session isn't active yet.
    try {
      VolumeController().getVolume().then((v) => _savedVolume = v);
      VolumeController().showSystemUI = false;
      VolumeController().listener(_onVolumeChange);
    } catch (_) {}
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  void setRootAction(VoidCallback action) => _rootAction = action;
  void clearRootAction() => _rootAction = null;

  // Screens that want to fully own the volume button (e.g. gripper screen)
  // register here. Override takes precedence over shutter / back-pop logic.
  void setOverride(VoidCallback fn) => _override = fn;
  void clearOverride() => _override = null;

  void _onVolumeChange(double _) {
    if (_resettingVolume) return;
    _resettingVolume = true;
    VolumeController().setVolume(_savedVolume);
    Future.delayed(const Duration(milliseconds: 400), () => _resettingVolume = false);
    _handlePress();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isVolumeKey = event.logicalKey == LogicalKeyboardKey.audioVolumeUp ||
        event.logicalKey == LogicalKeyboardKey.audioVolumeDown;
    if (!isVolumeKey) return false;
    _handlePress();
    return true;
  }

  void _handlePress() {
    if (_override != null) {
      _override!();
      return;
    }
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.canPop() ? nav.pop() : _rootAction?.call();
  }
}
