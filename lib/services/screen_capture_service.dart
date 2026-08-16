import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_macos_permissions/flutter_macos_permissions.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
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

  /// Captures the screen and returns the JPEG bytes plus its exact pixel
  /// dimensions - callers need those to convert coordinates Gemini gives
  /// (relative to this image) back into real screen coordinates.
  Future<({Uint8List bytes, int width, int height})> captureJpeg() async {
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

    final jpegBytes = Uint8List.fromList(
      img.encodeJpg(resized, quality: AppConfig.screenshotJpegQuality),
    );

    if (kDebugMode) {
      await _saveDebugCopy(jpegBytes);
    }

    return (bytes: jpegBytes, width: resized.width, height: resized.height);
  }

  /// Debug builds only: writes the exact bytes just sent to Gemini to
  /// the Desktop so they can be opened and visually checked (e.g. for
  /// mirroring/orientation bugs that wouldn't show up in coordinate math).
  Future<void> _saveDebugCopy(Uint8List jpegBytes) async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final debugFile = File('$home/Desktop/ai_as_ahuman_last_screenshot.jpg');
      await debugFile.writeAsBytes(jpegBytes);
    } catch (_) {
      // Diagnostic only - never let this break a real capture.
    }
  }
}
