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
  ///
  /// When the real screen size is passed, a labeled coordinate grid is
  /// drawn on top (see _drawCoordinateGrid) so Gemini can read off nearby
  /// gridline labels instead of estimating raw pixel positions from
  /// scratch - testing showed unaided estimates land wildly off on
  /// anything but the largest, most obvious targets.
  ///
  /// When cursorX/cursorY are also passed (the real-screen coordinates
  /// last given to SystemControlService.moveMouse/click/drag), a marker
  /// is drawn there too - the actual OS cursor isn't reliably visible in
  /// captures, so this gives Gemini a real, verifiable answer to "where
  /// is the cursor right now" instead of it having to assume its last
  /// move landed correctly. This is what lets it work the way a person
  /// does: move, look, check whether the cursor is actually on target,
  /// nudge and recheck if not, only then click.
  Future<({Uint8List bytes, int width, int height})> captureJpeg({
    int? screenWidth,
    int? screenHeight,
    int? cursorX,
    int? cursorY,
  }) async {
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

    if (screenWidth != null && screenHeight != null) {
      _drawCoordinateGrid(
        resized,
        realLeft: 0,
        realTop: 0,
        realRight: screenWidth,
        realBottom: screenHeight,
        step: 100,
      );

      if (cursorX != null && cursorY != null) {
        _drawCursorMarker(
          resized,
          realX: cursorX,
          realY: cursorY,
          realWidth: screenWidth,
          realHeight: screenHeight,
        );
      }
    }

    final jpegBytes = Uint8List.fromList(
      img.encodeJpg(resized, quality: AppConfig.screenshotJpegQuality),
    );

    if (kDebugMode) {
      await _saveDebugCopy(jpegBytes);
    }

    return (bytes: jpegBytes, width: resized.width, height: resized.height);
  }

  /// Draws gridlines every `step` real-screen pixels across
  /// [realLeft, realRight] x [realTop, realBottom], each labeled with its
  /// real-screen coordinate, directly onto `image` (mutated in place).
  /// Lets Gemini read off nearby labels and interpolate rather than
  /// estimating a raw pixel position with nothing to anchor against -
  /// unaided estimates were landing on the wrong UI element entirely in
  /// testing, not just imprecisely on the right one.
  void _drawCoordinateGrid(
    img.Image image, {
    required int realLeft,
    required int realTop,
    required int realRight,
    required int realBottom,
    required int step,
  }) {
    final color = img.ColorRgb8(255, 0, 255);
    final realWidth = realRight - realLeft;
    final realHeight = realBottom - realTop;
    if (realWidth <= 0 || realHeight <= 0) return;

    final firstX = (realLeft / step).ceil() * step;
    for (var realX = firstX; realX <= realRight; realX += step) {
      final px = ((realX - realLeft) / realWidth * image.width).round();
      img.drawLine(image, x1: px, y1: 0, x2: px, y2: image.height - 1, color: color);
      img.drawString(image, '$realX', font: img.arial14, x: px + 2, y: 2, color: color);
    }

    final firstY = (realTop / step).ceil() * step;
    for (var realY = firstY; realY <= realBottom; realY += step) {
      final py = ((realY - realTop) / realHeight * image.height).round();
      img.drawLine(image, x1: 0, y1: py, x2: image.width - 1, y2: py, color: color);
      img.drawString(image, '$realY', font: img.arial14, x: 2, y: py + 2, color: color);
    }
  }

  /// Marks where the cursor actually is, mapped from real screen
  /// coordinates into image pixels - a bright cyan crosshair, distinct
  /// from the grid's magenta, with its real coordinates labeled next to
  /// it so there's no ambiguity about exactly where it's pointing.
  void _drawCursorMarker(
    img.Image image, {
    required int realX,
    required int realY,
    required int realWidth,
    required int realHeight,
  }) {
    final px = (realX / realWidth * image.width).round();
    final py = (realY / realHeight * image.height).round();
    final color = img.ColorRgb8(0, 255, 255);

    img.drawCircle(image, x: px, y: py, radius: 10, color: color);
    img.drawLine(image, x1: px - 14, y1: py, x2: px + 14, y2: py, color: color);
    img.drawLine(image, x1: px, y1: py - 14, x2: px, y2: py + 14, color: color);
    img.drawString(
      image,
      'CURSOR ($realX,$realY)',
      font: img.arial14,
      x: px + 12,
      y: py + 12,
      color: color,
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
