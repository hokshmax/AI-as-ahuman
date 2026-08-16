import 'package:flutter/material.dart';

import '../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatRole.user;
    final isAction = message.role == ChatRole.action;
    final isSystem = message.role == ChatRole.system;

    final Color background;
    final IconData? icon;
    switch (message.role) {
      case ChatRole.user:
        background = theme.colorScheme.primaryContainer;
        icon = null;
      case ChatRole.assistant:
        background = theme.colorScheme.secondaryContainer;
        icon = Icons.smart_toy_outlined;
      case ChatRole.action:
        background = theme.colorScheme.tertiaryContainer;
        icon = Icons.touch_app_outlined;
      case ChatRole.system:
        background = theme.colorScheme.surfaceContainerHighest;
        icon = Icons.info_outline;
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                message.text,
                style: isSystem || isAction
                    ? theme.textTheme.bodySmall
                    : theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
