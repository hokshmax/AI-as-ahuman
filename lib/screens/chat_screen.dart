import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/agent_controller.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/status_indicator.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final AgentController _controller;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = AgentController()..addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    setState(() {});
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
    _controller.removeListener(_onControllerChanged);
    unawaited(_controller.shutdown());
    _controller.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _controller,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI as a Human'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: StatusIndicator(state: _controller.state)),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_controller.lastError != null)
              MaterialBanner(
                content: Text(_controller.lastError!),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _controller.lastError = null),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: _controller.messages.length,
                itemBuilder: (context, index) =>
                    ChatBubble(message: _controller.messages[index]),
              ),
            ),
            SafeArea(child: _buildInputBar(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(BuildContext context) {
    final isLive = _controller.state == SessionState.live;
    final isConnecting = _controller.state == SessionState.connecting;

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
                _controller.sendTypedMessage(text);
                _textController.clear();
              },
            ),
          ),
          if (isLive) ...[
            const SizedBox(width: 12),
            _buildMicStatus(context),
          ],
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: isConnecting
                ? null
                : () => isLive ? _controller.stop() : _controller.start(),
            icon: Icon(isLive ? Icons.stop : Icons.mic),
            label: Text(isLive ? 'Stop' : 'Start voice session'),
          ),
        ],
      ),
    );
  }

  /// Passive indicator only - listening is fully automatic. The mic is
  /// muted while Gemini is speaking (see AgentController.assistantSpeaking)
  /// so its own playback can't be picked back up and misread as an
  /// interruption; this just shows which state you're currently in.
  Widget _buildMicStatus(BuildContext context) {
    final speaking = _controller.assistantSpeaking;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          speaking ? Icons.volume_up : Icons.mic,
          size: 18,
          color: speaking ? Theme.of(context).colorScheme.tertiary : Colors.greenAccent,
        ),
        const SizedBox(width: 6),
        Text(speaking ? 'Gemini speaking' : 'Listening'),
      ],
    );
  }
}
