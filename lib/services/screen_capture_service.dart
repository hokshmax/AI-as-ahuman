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

  /// Captures the screen fresh and returns a magnified crop centered on
  /// (centerX, centerY) - real screen coordinates - covering a
  /// `regionSize`x`regionSize` real-pixel area around it, upscaled so
  /// small targets (Dock icons, tabs, checkboxes) are much easier to
  /// precisely locate than in a full, downscaled screenshot. Returns the
  /// real-screen-coordinate bounds of the crop alongside the JPEG so the
  /// caller can map a position within the zoomed image back to the real
  /// screen.
  Future<({Uint8List bytes, int left, int top, int right, int bottom})>
      captureZoomedJpeg({
    required int centerX,
    required int centerY,
    required int screenWidth,
    required int screenHeight,
    int regionSize = 300,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/screenshot_zoom_${_uuid.v4()}.png';

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
      // Best effort cleanup.
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw StateError('Screen capture failed: could not decode image.');
    }

    // The raw capture may be at a different pixel density than the real
    // (logical) screen size - e.g. 2x on Retina - so map the requested
    // real-screen region into the capture's own pixel space first.
    final scaleX = decoded.width / screenWidth;
    final scaleY = decoded.height / screenHeight;

    final halfW = (regionSize * scaleX / 2).round();
    final halfH = (regionSize * scaleY / 2).round();
    final nativeCenterX = (centerX * scaleX).round();
    final nativeCenterY = (centerY * scaleY).round();

    final cropLeft = (nativeCenterX - halfW).clamp(0, decoded.width - 1);
    final cropTop = (nativeCenterY - halfH).clamp(0, decoded.height - 1);
    final cropWidth = (halfW * 2).clamp(1, decoded.width - cropLeft);
    final cropHeight = (halfH * 2).clamp(1, decoded.height - cropTop);

    final cropped = img.copyCrop(
      decoded,
      x: cropLeft,
      y: cropTop,
      width: cropWidth,
      height: cropHeight,
    );
    // Upscale for clarity - this is the whole point of "zooming in".
    final zoomed = cropped.width < 700 ? img.copyResize(cropped, width: 700) : cropped;

    final jpegBytes = Uint8List.fromList(img.encodeJpg(zoomed, quality: 85));

    if (kDebugMode) {
      await _saveDebugCopy(jpegBytes, suffix: '_zoom');
    }

    // Convert the crop bounds back into real screen coordinates for the
    // caller to report to Gemini.
    return (
      bytes: jpegBytes,
      left: (cropLeft / scaleX).round(),
      top: (cropTop / scaleY).round(),
      right: ((cropLeft + cropWidth) / scaleX).round(),
      bottom: ((cropTop + cropHeight) / scaleY).round(),
    );
  }

  /// Debug builds only: writes the exact bytes just sent to Gemini to
  /// the Desktop so they can be opened and visually checked (e.g. for
  /// mirroring/orientation bugs that wouldn't show up in coordinate math).
  Future<void> _saveDebugCopy(Uint8List jpegBytes, {String suffix = ''}) async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      final debugFile =
          File('$home/Desktop/ai_as_ahuman_last_screenshot$suffix.jpg');
      await debugFile.writeAsBytes(jpegBytes);
    } catch (_) {
      // Diagnostic only - never let this break a real capture.
    }
  }
}
