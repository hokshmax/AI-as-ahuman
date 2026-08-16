import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_macos_permissions/flutter_macos_permissions.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';

/// Grabs the desktop screen and hands back a downscaled JPEG small enough
/// to stream to Gemini quickly and repeatedly.
class ScreenCaptureService {
  final _uuid = const Uuid();

  /// macOS requires explicit Screen Recording consent before any capture
  /// will actually produce an image - screen_capturer doesn't trigger that
  /// prompt itself, so this asks for it up front. No-op elsewhere.
  Future<void> ensurePermission() async {
    if (!Platform.isMacOS) return;
    final status = await FlutterMacosPermissions.requestScreenRecording();
    if (!status.isGranted) {
      throw StateError(
        'Screen Recording permission denied. Grant it under System '
        'Settings -> Privacy & Security -> Screen Recording and restart '
        'the app.',
      );
    }
  }

  Future<Uint8List> captureJpeg() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/screenshot_${_uuid.v4()}.png';

    final captured = await ScreenCapturer.instance.capture(
      mode: CaptureMode.screen,
      imagePath: path,
      silent: true,
    );

    final file = File(captured?.imagePath ?? path);
    if (!await file.exists()) {
      throw StateError('Screen capture failed: no file produced.');
    }

    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {
      // Best effort cleanup; a leftover temp screenshot isn't fatal.
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw StateError('Screen capture failed: could not decode image.');
    }

    final resized = decoded.width > AppConfig.screenshotMaxWidth
        ? img.copyResize(decoded, width: AppConfig.screenshotMaxWidth)
        : decoded;

    return Uint8List.fromList(
      img.encodeJpg(resized, quality: AppConfig.screenshotJpegQuality),
    );
  }

  /// Physical screen size in pixels, used to keep mouse coordinates that
  /// Gemini reasons about (from the possibly-downscaled screenshot)
  /// consistent with the real display.
  Future<({int width, int height})> screenSize() async {
    final display = await screenRetriever.getPrimaryDisplay();
    final size = display.size;
    return (width: size.width.round(), height: size.height.round());
  }
}
