import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_macos_permissions/flutter_macos_permissions.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:screen_capturer/screen_capturer.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';

/// Everything _processScreenshot needs, bundled into one value so it can
/// be handed across the isolate boundary compute() spawns - only simple
/// transferable types (Uint8List, int, bool) are allowed in that message.
typedef _ScreenshotJob = ({
  Uint8List pngBytes,
  int maxWidth,
  int quality,
  int? screenWidth,
  int? screenHeight,
  int? cursorX,
  int? cursorY,
  bool includeOverlay,
});

typedef _ScreenshotResult = ({
  Uint8List bytes,
  Uint8List? overlayBytes,
  int width,
  int height,
});

/// Decodes the raw captured PNG, downscales it, and JPEG-encodes it (plus
/// the grid/cursor overlay, if requested) - run via compute() on a
/// background isolate rather than the main one. This is genuinely
/// CPU-heavy work (PNG decode, resize, JPEG encode of a 1000px+ image),
/// and doing it synchronously on the main isolate - the same isolate
/// receiving Gemini's audio over the WebSocket and feeding the speaker -
/// blocked audio processing for however long it took, causing an audible
/// stutter/cut in playback every time a screenshot tick landed. Must be a
/// top-level function (compute() can't call instance/closure methods).
_ScreenshotResult _processScreenshot(_ScreenshotJob job) {
  final decoded = img.decodeImage(job.pngBytes);
  if (decoded == null) {
    throw StateError('Screen capture failed: could not decode image.');
  }

  final resized = decoded.width > job.maxWidth
      ? img.copyResize(decoded, width: job.maxWidth)
      : decoded;

  final jpegBytes = Uint8List.fromList(
    img.encodeJpg(resized, quality: job.quality),
  );

  Uint8List? overlayBytes;
  if (job.includeOverlay && job.screenWidth != null && job.screenHeight != null) {
    final overlay = resized.clone();
    _drawCoordinateGrid(
      overlay,
      realLeft: 0,
      realTop: 0,
      realRight: job.screenWidth!,
      realBottom: job.screenHeight!,
      step: 100,
    );

    if (job.cursorX != null && job.cursorY != null) {
      _drawCursorMarker(
        overlay,
        realX: job.cursorX!,
        realY: job.cursorY!,
        realWidth: job.screenWidth!,
        realHeight: job.screenHeight!,
      );
    }

    overlayBytes = Uint8List.fromList(
      img.encodeJpg(overlay, quality: job.quality),
    );
  }

  return (
    bytes: jpegBytes,
    overlayBytes: overlayBytes,
    width: resized.width,
    height: resized.height,
  );
}

/// Draws gridlines every `step` real-screen pixels across
/// [realLeft, realRight] x [realTop, realBottom], each labeled with its
/// real-screen coordinate, directly onto `image` (mutated in place). Lets
/// Gemini read off nearby labels and interpolate rather than estimating a
/// raw pixel position with nothing to anchor against - unaided estimates
/// were landing on the wrong UI element entirely in testing, not just
/// imprecisely on the right one.
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

/// Marks where the cursor actually is, mapped from real screen coordinates
/// into image pixels - a bright cyan crosshair, distinct from the grid's
/// magenta, with its real coordinates labeled next to it so there's no
/// ambiguity about exactly where it's pointing.
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

  /// Captures the screen and returns the clean JPEG bytes plus its exact
  /// pixel dimensions - callers need those to convert coordinates Gemini
  /// gives (relative to this image) back into real screen coordinates.
  ///
  /// When the real screen size is passed, a *second* JPEG is also
  /// returned (`overlayBytes`) - the same capture, but with a labeled
  /// coordinate grid and, if cursorX/cursorY are given, a cursor marker
  /// drawn on it. This is deliberately a separate image rather than drawn
  /// onto the one and only screenshot: gridlines/labels drawn directly
  /// over the real image can literally paint over the exact pixels of a
  /// small target (an icon, a checkbox), which would make locating it
  /// *harder*, not easier. Sending both lets Gemini identify the target
  /// precisely in the clean image, then cross-reference the gridded one
  /// for its coordinates. Pass `includeOverlay: false` to skip building
  /// it entirely (see [_processScreenshot]'s doc comment).
  Future<({Uint8List bytes, Uint8List? overlayBytes, int width, int height})>
      captureJpeg({
    int? screenWidth,
    int? screenHeight,
    int? cursorX,
    int? cursorY,
    bool includeOverlay = true,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/screenshot_${_uuid.v4()}.png';

    // A hung native capture call (e.g. a permission dialog silently
    // waiting for a click) would otherwise block this - and every tool
    // call queued behind it - forever. Fail fast instead.
    final captured = await ScreenCapturer.instance
        .capture(mode: CaptureMode.screen, imagePath: path, silent: true)
        .timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw TimeoutException(
            'Screen capture timed out after 8s.',
          ),
        );

    final file = File(captured?.imagePath ?? path);
    if (!await file.exists()) {
      throw StateError('Screen capture failed: no file produced.');
    }

    final pngBytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {
      // Best effort cleanup; a leftover temp screenshot isn't fatal.
    }

    final result = await compute(_processScreenshot, (
      pngBytes: pngBytes,
      maxWidth: AppConfig.screenshotMaxWidth,
      quality: AppConfig.screenshotJpegQuality,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      cursorX: cursorX,
      cursorY: cursorY,
      includeOverlay: includeOverlay,
    ));

    if (kDebugMode) {
      await _saveDebugCopy(result.bytes);
      if (result.overlayBytes != null) {
        await _saveDebugCopy(result.overlayBytes!, suffix: '_grid');
      }
    }

    return result;
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
