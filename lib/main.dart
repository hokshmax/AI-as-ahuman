import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'config/app_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // window_manager has no Android/iOS implementation, and a floating
  // always-on-top overlay doesn't fit a phone's full-screen UI paradigm
  // anyway - FloatingShell renders a normal full-screen view there
  // instead, so this whole block is skipped on those platforms.
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    final options = WindowOptions(
      size: AppConfig.floatingCollapsedSize,
      minimumSize: AppConfig.floatingCollapsedSize,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: true,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const AiAsAHumanApp());
}
