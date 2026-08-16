import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BleGripperService — manages the BLE connection to the ShelfScan-Servo ESP32.
//
// Protocol (sent as UTF-8 strings to the characteristic):
//   T<dir><ms>  timed move:  T0800 = open 800 ms,  T11200 = close 1200 ms
//   S           emergency stop
//   H           home (open fully, resets position reference)
//
// Position is tracked in software: 0.0 = fully open, 1.0 = fully closed.
// ─────────────────────────────────────────────────────────────────────────────

enum GripperState { disconnected, scanning, connecting, connected }

class BleGripperService extends ChangeNotifier {
  BleGripperService._();
  static final instance = BleGripperService._();

  static const _deviceName  = 'ShelfScan-Servo';
  static const _serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const _charUuid    = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

  // Full open→close travel in milliseconds. Tune this to your mechanism.
  static const _fullTravelMs = 3000;

  BluetoothDevice?           _device;
  BluetoothCharacteristic?   _char;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  GripperState _state    = GripperState.disconnected;
  double       _position = 0.0;   // 0 = open, 1 = closed
  bool         _moving   = false;
  String?      _error;

  GripperState get state    => _state;
  double       get position => _position;
  bool         get moving   => _moving;
  String?      get error    => _error;
  bool         get connected => _state == GripperState.connected;

  // ── Scan & connect ──────────────────────────────────────────────────────────

  Future<void> connect() async {
    if (_state != GripperState.disconnected) return;
    _setError(null);
    _setState(GripperState.scanning);

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(_serviceUuid)],
        timeout: const Duration(seconds: 8),
      );

      BluetoothDevice? found;
      await for (final results in FlutterBluePlus.scanResults) {
        for (final r in results) {
          if (r.device.platformName == _deviceName ||
              r.advertisementData.serviceUuids
                  .any((u) => u.toString().toLowerCase() == _serviceUuid)) {
            found = r.device;
            break;
          }
        }
        if (found != null) break;
      }
      await FlutterBluePlus.stopScan();

      if (found == null) {
        _setError('Gripper not found — make sure it\'s powered on nearby');
        _setState(GripperState.disconnected);
        return;
      }

      _setState(GripperState.connecting);
      _device = found;

      await found.connect(timeout: const Duration(seconds: 8));

      _connSub = found.connectionState.listen((cs) {
        if (cs == BluetoothConnectionState.disconnected) {
          _char = null;
          _moving = false;
          _setState(GripperState.disconnected);
        }
      });

      final services = await found.discoverServices();
      for (final s in services) {
        if (s.serviceUuid.toString().toLowerCase() == _serviceUuid) {
          for (final c in s.characteristics) {
            if (c.characteristicUuid.toString().toLowerCase() == _charUuid) {
              _char = c;
            }
          }
        }
      }

      if (_char == null) {
        await found.disconnect();
        _setError('Gripper found but service not available');
        _setState(GripperState.disconnected);
        return;
      }

      _setState(GripperState.connected);
    } catch (e) {
      await FlutterBluePlus.stopScan();
      _setError('Connection failed: $e');
      _setState(GripperState.disconnected);
    }
  }

  Future<void> disconnect() async {
    await _connSub?.cancel();
    _connSub = null;
    await _device?.disconnect();
    _device = null;
    _char   = null;
    _moving = false;
    _setState(GripperState.disconnected);
  }

  // ── Movement ────────────────────────────────────────────────────────────────

  /// Move gripper to [target] (0.0 = open, 1.0 = closed).
  Future<void> moveTo(double target) async {
    if (!connected || _char == null || _moving) return;
    target = target.clamp(0.0, 1.0);

    final delta = target - _position;
    if (delta.abs() < 0.01) return;

    final dir = delta > 0 ? 1 : 0;          // 1 = close, 0 = open
    final ms  = (delta.abs() * _fullTravelMs).round().clamp(1, 9999);

    _moving = true;
    notifyListeners();

    await _write('T$dir$ms');

    // Optimistically update position as the servo moves
    await Future.delayed(Duration(milliseconds: ms));
    _position = target;
    _moving   = false;
    notifyListeners();
  }

  Future<void> openFull()  => moveTo(0.0);
  Future<void> closeFull() => moveTo(1.0);

  Future<void> stop() async {
    if (!connected || _char == null) return;
    await _write('S');
    _moving = false;
    notifyListeners();
  }

  /// Home: drive open direction for full travel, then reset position to 0.
  Future<void> home() async {
    if (!connected || _char == null) return;
    _moving = true;
    notifyListeners();
    await _write('H');
    await Future.delayed(const Duration(milliseconds: _fullTravelMs + 200));
    _position = 0.0;
    _moving   = false;
    notifyListeners();
  }

  // ── Internals ───────────────────────────────────────────────────────────────

  Future<void> _write(String cmd) async {
    try {
      final bytes = cmd.codeUnits;
      await _char!.write(bytes, withoutResponse: true);
      debugPrint('[BLE] → $cmd');
    } catch (e) {
      debugPrint('[BLE] write error: $e');
      _setError('Command failed: $e');
    }
  }

  void _setState(GripperState s) {
    _state = s;
    notifyListeners();
  }

  void _setError(String? e) {
    _error = e;
    // Don't notifyListeners here — caller will do it via _setState
  }
}
