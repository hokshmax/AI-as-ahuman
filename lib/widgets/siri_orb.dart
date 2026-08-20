import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/agent_controller.dart';

/// What the orb is visually communicating right now - distinct from
/// SessionState because "speaking" needs its own look even though it's
/// still SessionState.live under the hood.
enum OrbState { idle, connecting, listening, speaking, error }

/// Maps the controller's actual state onto what the orb should show -
/// the one place this mapping happens, so every place that renders an
/// orb (the collapsed pill, the expanded header, the mobile AppBar)
/// stays in sync automatically.
OrbState orbStateFor(AgentController controller) {
  if (controller.state == SessionState.error) return OrbState.error;
  if (controller.state == SessionState.connecting) return OrbState.connecting;
  if (controller.state == SessionState.live) {
    return controller.assistantSpeaking ? OrbState.speaking : OrbState.listening;
  }
  return OrbState.idle;
}

/// A Siri/assistant-style animated orb: a glowing gradient core with
/// expanding rings when actively listening or speaking, a slow gentle
/// "breathing" scale otherwise. Purely state-driven (not real audio
/// amplitude) - simple and reliable rather than needing to plumb mic/
/// playback levels all the way up to the widget tree.
class SiriOrb extends StatefulWidget {
  const SiriOrb({super.key, required this.state, this.size = 56});

  final OrbState state;
  final double size;

  @override
  State<SiriOrb> createState() => _SiriOrbState();
}

class _SiriOrbState extends State<SiriOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _durationFor(widget.state),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant SiriOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _controller.duration = _durationFor(widget.state);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static Duration _durationFor(OrbState state) => switch (state) {
        OrbState.idle => const Duration(seconds: 4),
        OrbState.connecting => const Duration(milliseconds: 900),
        OrbState.listening => const Duration(milliseconds: 1600),
        OrbState.speaking => const Duration(milliseconds: 700),
        OrbState.error => const Duration(seconds: 4),
      };

  static List<Color> _colorsFor(OrbState state) => switch (state) {
        OrbState.idle => [Colors.grey.shade500, Colors.grey.shade800],
        OrbState.connecting => [Colors.amber.shade300, Colors.orange.shade700],
        OrbState.listening => [Colors.cyanAccent.shade200, Colors.blueAccent.shade700],
        OrbState.speaking => [Colors.purpleAccent.shade100, Colors.deepPurple.shade600],
        OrbState.error => [Colors.redAccent.shade100, Colors.red.shade900],
      };

  @override
  Widget build(BuildContext context) {
    final colors = _colorsFor(widget.state);
    final active = widget.state == OrbState.listening ||
        widget.state == OrbState.speaking ||
        widget.state == OrbState.connecting;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (active)
                for (var i = 0; i < 3; i++) _ring(colors, t, i),
              _core(colors, t, active),
            ],
          ),
        );
      },
    );
  }

  Widget _ring(List<Color> colors, double t, int i) {
    final phase = (t + i / 3) % 1.0;
    final scale = 0.55 + phase * 0.6;
    final opacity = (1 - phase).clamp(0.0, 1.0) * 0.45;
    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colors.first, width: 2),
          ),
        ),
      ),
    );
  }

  Widget _core(List<Color> colors, double t, bool active) {
    final pulse = active ? 0.88 + 0.12 * math.sin(t * 2 * math.pi) : 1.0;
    return Transform.scale(
      scale: pulse,
      child: Container(
        width: widget.size * 0.62,
        height: widget.size * 0.62,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.last.withOpacity(0.6),
              blurRadius: active ? 18 : 8,
              spreadRadius: active ? 2 : 0,
            ),
          ],
        ),
      ),
    );
  }
}
