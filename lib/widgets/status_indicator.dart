import 'package:flutter/material.dart';

import '../services/agent_controller.dart';

class StatusIndicator extends StatelessWidget {
  const StatusIndicator({super.key, required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      SessionState.idle => (Colors.grey, 'Idle'),
      SessionState.connecting => (Colors.amber, 'Connecting...'),
      SessionState.live => (Colors.greenAccent, 'Live'),
      SessionState.error => (Colors.redAccent, 'Error'),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
