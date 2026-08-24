import 'package:flutter/services.dart';
import 'package:volume_controller/volume_controller.dart';
import 'nav.dart';

class VolumeShutterService {
  VolumeShutterService._();
  static final instance = VolumeShutterService._();

  VoidCallback? _rootAction;
  double _savedVolume = 0.5;
  // Guards against re-entering _triggerShutter while we reset volume to saved level.
  bool _resettingVolume = false;

  void init() {
    VolumeController().getVolume().then((v) => _savedVolume = v);
    VolumeController().showSystemUI = false;
    VolumeController().listener(_onVolumeChange);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  void setRootAction(VoidCallback action) => _rootAction = action;
  void clearRootAction() => _rootAction = null;

  void _onVolumeChange(double _) {
    if (_resettingVolume) return;
    _resettingVolume = true;
    VolumeController().setVolume(_savedVolume);
    Future.delayed(const Duration(milliseconds: 400), () => _resettingVolume = false);
    _triggerShutter();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isVolumeKey = event.logicalKey == LogicalKeyboardKey.audioVolumeUp ||
        event.logicalKey == LogicalKeyboardKey.audioVolumeDown;
    if (!isVolumeKey) return false;
    _triggerShutter();
    return true;
  }

  void _triggerShutter() {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    nav.canPop() ? nav.pop() : _rootAction?.call();
  }
}
