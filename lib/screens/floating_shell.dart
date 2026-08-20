import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../config/app_config.dart';
import '../services/agent_controller.dart';
import '../widgets/assistant_panel.dart';
import '../widgets/siri_orb.dart';

/// True only on the desktop platforms this app actually runs the
/// floating, always-on-top overlay window on - window_manager has no
/// Android/iOS implementation, and a floating desktop-style overlay
/// doesn't fit a phone's own full-screen UI paradigm anyway. Android
/// gets a normal full-screen view instead (see _buildFullScreen).
final bool isFloatingDesktopOverlay =
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// The app's root widget. On desktop this *is* the floating overlay -
/// there's no separate full-size app window behind it, the whole app
/// lives in one small always-on-top window that starts as a collapsed
/// Siri-like orb pill and expands into the full chat panel on demand.
/// On Android/other platforms it's just a normal full-screen Scaffold.
class FloatingShell extends StatefulWidget {
  const FloatingShell({super.key});

  @override
  State<FloatingShell> createState() => _FloatingShellState();
}

class _FloatingShellState extends State<FloatingShell> {
  late final AgentController _controller;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _controller = AgentController()..addListener(_onControllerChanged);
  }

  void _onControllerChanged() => setState(() {});

  Future<void> _setExpanded(bool expanded) async {
    setState(() => _expanded = expanded);
    if (isFloatingDesktopOverlay) {
      await windowManager.setSize(
        expanded ? AppConfig.floatingExpandedSize : AppConfig.floatingCollapsedSize,
        animate: true,
      );
    }
  }

  Future<void> _close() async {
    await _controller.shutdown();
    if (isFloatingDesktopOverlay) {
      await windowManager.close();
    }
    // No real window to close on mobile - the session is stopped above,
    // which is the meaningful part of "close" there; the user backs out
    // of the app the normal Android way.
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    unawaited(_controller.shutdown());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _controller,
      child: isFloatingDesktopOverlay
          ? _buildFloatingOverlay(context)
          : _buildFullScreen(context),
    );
  }

  Widget _buildFullScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SiriOrb(state: orbStateFor(_controller), size: 28),
            const SizedBox(width: 10),
            const Text('AI as a Human'),
          ],
        ),
      ),
      body: AssistantPanel(controller: _controller),
    );
  }

  Widget _buildFloatingOverlay(BuildContext context) {
    // The window itself is transparent (set in main.dart) - this rounded
    // panel is the only thing actually visible, floating over whatever
    // else is on screen. Sized/animated to match whatever OS window size
    // _setExpanded() just requested, so the panel and the real window
    // bounds change together instead of one lagging the other.
    return Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: _expanded
            ? AppConfig.floatingExpandedSize.width
            : AppConfig.floatingCollapsedSize.width,
        height: _expanded
            ? AppConfig.floatingExpandedSize.height
            : AppConfig.floatingCollapsedSize.height,
        decoration: BoxDecoration(
          color: const Color(0xF0141018),
          borderRadius: BorderRadius.circular(_expanded ? 20 : 48),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 2),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: _expanded ? _buildExpanded(context) : _buildCollapsed(context),
      ),
    );
  }

  Widget _buildCollapsed(BuildContext context) {
    // DragToMoveArea makes the whole pill draggable (this window has no
    // OS title bar to drag by, since it's frameless) while still letting
    // the icon buttons inside receive their own taps.
    return DragToMoveArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SiriOrb(state: orbStateFor(_controller), size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _statusLabel(_controller),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.expand_more, color: Colors.white70),
              tooltip: 'More',
              onPressed: () => _setExpanded(true),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white70),
              tooltip: 'Close',
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context) {
    return Column(
      children: [
        DragToMoveArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                SiriOrb(state: orbStateFor(_controller), size: 32),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'AI as a Human',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.expand_less, color: Colors.white70),
                  tooltip: 'Collapse',
                  onPressed: () => _setExpanded(false),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: 'Close',
                  onPressed: _close,
                ),
              ],
            ),
          ),
        ),
        Expanded(child: AssistantPanel(controller: _controller)),
      ],
    );
  }
}

String _statusLabel(AgentController controller) => switch (controller.state) {
      SessionState.idle => 'Tap to start',
      SessionState.connecting => 'Connecting...',
      SessionState.live =>
        controller.assistantSpeaking ? 'Speaking...' : 'Listening...',
      SessionState.error => 'Error - tap for details',
    };
