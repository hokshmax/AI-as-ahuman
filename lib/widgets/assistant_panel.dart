import 'package:flutter/material.dart';

import '../services/agent_controller.dart';
import 'chat_bubble.dart';

/// The chat transcript + input bar content - shared between the desktop
/// floating overlay's expanded view (FloatingShell) and the mobile
/// full-screen view, so there's exactly one place that renders the
/// actual conversation rather than two copies that could drift apart.
/// Header chrome (title, orb, collapse/close buttons) is deliberately
/// NOT part of this widget - those differ enough between the two hosts
/// (a draggable floating header vs. a normal AppBar) that the callers
/// build them separately.
class AssistantPanel extends StatefulWidget {
  const AssistantPanel({super.key, required this.controller});

  final AgentController controller;

  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant AssistantPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new message arrived (the controller notified listeners, which
    // rebuilt this widget) - scroll to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return Column(
      children: [
        if (controller.lastError != null)
          MaterialBanner(
            content: Text(controller.lastError!),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            actions: [
              TextButton(
                onPressed: () => setState(() => controller.lastError = null),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: controller.messages.length,
            itemBuilder: (context, index) =>
                ChatBubble(message: controller.messages[index]),
          ),
        ),
        SafeArea(top: false, child: _buildInputBar(context, controller)),
      ],
    );
  }

  Widget _buildInputBar(BuildContext context, AgentController controller) {
    final isLive = controller.state == SessionState.live;
    final isConnecting = controller.state == SessionState.connecting;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              enabled: isLive,
              decoration: const InputDecoration(
                hintText: 'Type instead of talking...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (text) {
                controller.sendTypedMessage(text);
                _textController.clear();
              },
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: isConnecting
                ? null
                : () => isLive ? controller.stop() : controller.start(),
            icon: Icon(isLive ? Icons.stop : Icons.mic),
            label: Text(isLive ? 'Stop' : 'Start'),
          ),
        ],
      ),
    );
  }
}
