import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

enum GripperState { disconnected, scanning, connecting, connected }

class BleGripperService extends ChangeNotifier {
  BleGripperService._();
  static final instance = BleGripperService._();

  static const _deviceName  = 'ShelfScan-Servo';
  static const _serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const _charUuid    = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  // Tune to match the actual open→close travel time of the mechanism.
  static const _fullTravelMs = 3000;

  BluetoothDevice?          _device;
  BluetoothCharacteristic?  _char;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _positionTicker;

  GripperState _state    = GripperState.disconnected;
  double       _position = 0.0; // 0 = fully open, 1 = fully closed
  bool         _moving   = false;
  String?      _error;

  GripperState get state    => _state;
  double       get position => _position;
  bool         get moving   => _moving;
  String?      get error    => _error;
  bool         get connected => _state == GripperState.connected;

  Future<void> connect() async {
    if (_state != GripperState.disconnected) return;
    _error = null;
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
        _error = 'Gripper not found — make sure it\'s powered on nearby';
        _setState(GripperState.disconnected);
        return;
      }

      _setState(GripperState.connecting);
      _device = found;
      await found.connect(timeout: const Duration(seconds: 8));

      _connSub = found.connectionState.listen((cs) {
        if (cs == BluetoothConnectionState.disconnected) {
          _char   = null;
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
        _error = 'Gripper found but service not available';
        _setState(GripperState.disconnected);
        return;
      }

      _setState(GripperState.connected);
    } catch (e) {
      await FlutterBluePlus.stopScan();
      _error = 'Connection failed: $e';
      _setState(GripperState.disconnected);
    }
  }

  Future<void> disconnect() async {
    await _connSub?.cancel();
    _connSub = null;
    await _device?.disconnect();
    _device  = null;
    _char    = null;
    _moving  = false;
    _setState(GripperState.disconnected);
  }

  // dir: 0 = open, 1 = close. Hold the call; invoke stopMove() on release.
  void startMove(int dir) {
    if (!connected || _char == null) return;
    _moving = true;
    _write('T${dir}9999');
    _positionTicker?.cancel();
    _positionTicker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      const delta = 33 / _fullTravelMs;
      _position = (dir == 1 ? _position + delta : _position - delta).clamp(0.0, 1.0);
      notifyListeners();
    });
  }

  Future<void> stopMove() async {
    _positionTicker?.cancel();
    _positionTicker = null;
    _moving = false;
    if (!connected || _char == null) return;
    await _write('S');
    notifyListeners();
  }

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

  Future<void> _write(String cmd) async {
    try {
      await _char!.write(cmd.codeUnits, withoutResponse: false);
      debugPrint('[BLE] → $cmd');
    } catch (e) {
      debugPrint('[BLE] write error: $e');
      _error = 'Command failed: $e';
      notifyListeners();
    }
  }

  void _setState(GripperState s) {
    _state = s;
    notifyListeners();
  }
}
