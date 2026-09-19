import 'dart:async';
import 'package:flutter/material.dart';
import 'ble_gripper_service.dart';
import 'design.dart';
import 'volume_shutter_service.dart';

class GripperScreen extends StatefulWidget {
  const GripperScreen({super.key});

  @override
  State<GripperScreen> createState() => _GripperScreenState();
}

class _GripperScreenState extends State<GripperScreen> {
  final _gripper = BleGripperService.instance;

  @override
  void initState() {
    super.initState();
    VolumeShutterService.instance.setOverride(_garageDoorToggle);
  }

  @override
  void dispose() {
    VolumeShutterService.instance.clearOverride();
    super.dispose();
  }

  // Press once to start moving toward the opposite end; press again to stop.
  void _garageDoorToggle() {
    if (_gripper.moving) {
      _gripper.stopMove();
    } else {
      final dir = _gripper.position < 0.5 ? 1 : 0; // near open → close, near closed → open
      _gripper.startMove(dir);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgDark,
      appBar: AppBar(
        backgroundColor: kBgDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('Book Gripper', style: kHeading(18, color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListenableBuilder(
        listenable: _gripper,
        builder: (_, __) => _body(),
      ),
    );
  }

  Widget _body() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        children: [
          _statusRow(),
          const SizedBox(height: 24),
          Expanded(child: _positionSection()),
          const SizedBox(height: 24),
          _controlRow(),
          const SizedBox(height: 16),
          _selfieStickHint(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _statusRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _statusPill(),
        if (_gripper.error != null)
          Flexible(
            child: Text(
              _gripper.error!,
              style: kLabel(11, color: kRust),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        _connectButton(),
      ],
    );
  }

  Widget _statusPill() {
    final (label, color) = switch (_gripper.state) {
      GripperState.disconnected => ('Disconnected', kTextFaint),
      GripperState.scanning     => ('Scanning…', kGold),
      GripperState.connecting   => ('Connecting…', kGold),
      GripperState.connected    => ('Connected', const Color(0xFF4CAF50)),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: kLabel(13, color: color)),
      ],
    );
  }

  Widget _connectButton() {
    final isDisconnected = _gripper.state == GripperState.disconnected;
    final isBusy = _gripper.state == GripperState.scanning ||
        _gripper.state == GripperState.connecting;
    return TextButton(
      onPressed: isBusy ? null : (isDisconnected ? _gripper.connect : _gripper.disconnect),
      style: TextButton.styleFrom(
        foregroundColor: isDisconnected ? kGold : kRust,
      ),
      child: Text(
        isBusy ? 'Searching…' : (isDisconnected ? 'Connect' : 'Disconnect'),
        style: kLabel(13),
      ),
    );
  }

  Widget _positionSection() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('OPEN', style: kLabel(11, color: kTextFaint, tracking: 1.5)),
            Text('CLOSED', style: kLabel(11, color: kTextFaint, tracking: 1.5)),
          ],
        ),
        const SizedBox(height: 10),
        _positionBar(),
        const SizedBox(height: 10),
        Text(
          _gripper.moving ? 'Moving…' : '${(_gripper.position * 100).round()}%',
          style: kLabel(12, color: _gripper.moving ? kGold : kTextFaint),
        ),
      ],
    );
  }

  Widget _positionBar() {
    return LayoutBuilder(
      builder: (_, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: const Color(0xFF2A2927),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 50),
              height: 6,
              width: width * _gripper.position,
              decoration: BoxDecoration(
                color: kGold,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 50),
              left: (width * _gripper.position - 10).clamp(0, width - 20),
              child: Container(
                width: 20, height: 20,
                decoration: BoxDecoration(
                  color: kGold,
                  shape: BoxShape.circle,
                  border: Border.all(color: kBgDark, width: 3),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _controlRow() {
    return Row(
      children: [
        Expanded(child: _HoldButton(
          label: 'OPEN',
          icon: Icons.chevron_left,
          enabled: _gripper.connected,
          onStart: () => _gripper.startMove(0),
          onEnd: _gripper.stopMove,
        )),
        const SizedBox(width: 16),
        _homeButton(),
        const SizedBox(width: 16),
        Expanded(child: _HoldButton(
          label: 'CLOSE',
          icon: Icons.chevron_right,
          iconLeft: false,
          enabled: _gripper.connected,
          onStart: () => _gripper.startMove(1),
          onEnd: _gripper.stopMove,
        )),
      ],
    );
  }

  Widget _homeButton() {
    return GestureDetector(
      onTap: _gripper.connected ? _gripper.home : null,
      child: Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          color: _gripper.connected
              ? const Color(0xFF1E1D1C)
              : const Color(0xFF161514),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF2A2927)),
        ),
        child: Icon(
          Icons.home_outlined,
          color: _gripper.connected ? kTextFaint : const Color(0xFF3A3837),
          size: 22,
        ),
      ),
    );
  }

  Widget _selfieStickHint() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.volume_up, color: Color(0xFF3A3837), size: 14),
        const SizedBox(width: 6),
        Text(
          'Volume button opens / closes gripper',
          style: kLabel(11, color: const Color(0xFF3A3837)),
        ),
      ],
    );
  }
}

class _HoldButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool iconLeft;
  final bool enabled;
  final VoidCallback onStart;
  final Future<void> Function() onEnd;

  const _HoldButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onStart,
    required this.onEnd,
    this.iconLeft = true,
  });

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  bool _pressed = false;

  void _down() {
    if (!widget.enabled) return;
    setState(() => _pressed = true);
    widget.onStart();
  }

  void _up() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 56,
        decoration: BoxDecoration(
          color: _pressed
              ? kGold.withValues(alpha: 0.15)
              : (widget.enabled ? const Color(0xFF1E1D1C) : const Color(0xFF161514)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _pressed ? kGold : const Color(0xFF2A2927),
            width: _pressed ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: widget.iconLeft
              ? [
                  Icon(widget.icon, color: _buttonColor(), size: 18),
                  const SizedBox(width: 4),
                  Text(widget.label, style: kLabel(12, color: _buttonColor(), tracking: 1.5)),
                ]
              : [
                  Text(widget.label, style: kLabel(12, color: _buttonColor(), tracking: 1.5)),
                  const SizedBox(width: 4),
                  Icon(widget.icon, color: _buttonColor(), size: 18),
                ],
        ),
      ),
    );
  }

  Color _buttonColor() {
    if (!widget.enabled) return const Color(0xFF3A3837);
    return _pressed ? kGold : kTextFaint;
  }
}
