import 'package:flutter/material.dart';

import 'screens/chat_screen.dart';

class AiAsAHumanApp extends StatelessWidget {
  const AiAsAHumanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI as a Human',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}
