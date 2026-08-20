import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/chat_message.dart';
import 'audio_service.dart';
import 'gemini_live_service.dart';
import 'screen_capture_service.dart';
import 'system_control_service.dart';

enum SessionState { idle, connecting, live, error }

/// Coordinates the whole loop: mic -> Gemini -> (audio back to speakers)
/// and (tool calls -> real mouse/keyboard/screenshots) -> back to Gemini.
class AgentController extends ChangeNotifier {
  AgentController({
    GeminiLiveService? liveService,
    AudioService? audioService,
    ScreenCaptureService? screenCaptureService,
    SystemControlService? systemControlService,
  })  : _live = liveService ?? GeminiLiveService(),
        _audio = audioService ?? AudioService(),
        _screen = screenCaptureService ?? ScreenCaptureService(),
        _system = systemControlService ?? SystemControlService();

  final GeminiLiveService _live;
  final AudioService _audio;
  final ScreenCaptureService _screen;
  final SystemControlService _system;

  final List<ChatMessage> messages = [];
  final List<String> actionLog = [];

  SessionState state = SessionState.idle;
  String? lastError;

  /// The real screen size, in the coordinate space SystemControlService's
  /// mouse calls operate in. Fetched once at session start.
  ({int width, int height})? _realScreenSize;

  /// False when ScreenCaptureService.ensurePermission() failed at
  /// session start - currently always false on Android, which has no
  /// screen capture implementation yet (see its doc comment). Screenshot
  /// pushing is skipped entirely rather than retrying and failing on
  /// every _screenshotTimer tick.
  bool _screenCaptureAvailable = true;

  /// True from the moment Gemini's reply audio starts until shortly
  /// after its turn ends. Mic audio is never forwarded during this
  /// window (see the micStream listener in start()) so its own
  /// playback - echoing back through an unmuted mic on a laptop with
  /// no headphones - can never be misread by the server's voice
  /// detection as the user interrupting it. This makes listening fully
  /// automatic (no push-to-talk button) while still preventing
  /// self-interruption.
  bool assistantSpeaking = false;
  Timer? _unmuteTimer;

  /// Pushes a fresh screenshot on AppConfig.screenshotInterval so Gemini
  /// has a continuously updated view - genuine screen sharing rather
  /// than only ever seeing a frame it explicitly requested.
  Timer? _screenshotTimer;

  final List<StreamSubscription<dynamic>> _subs = [];

  Future<void> start() async {
    if (state == SessionState.connecting || state == SessionState.live) return;
    state = SessionState.connecting;
    lastError = null;
    notifyListeners();

    try {
      var audioAvailable = true;
      try {
        await _audio.init();
      } catch (e, st) {
        audioAvailable = false;
        debugPrint('[AgentController] audio init failed: $e\n$st');
        _addMessage(
          ChatRole.system,
          'Microphone/speaker unavailable ($e) - continuing in '
          'text-only mode. Full trace is in the terminal.',
        );
      }

      try {
        await _screen.ensurePermission();
        _realScreenSize = await _system.screenSize();
        debugPrint('[AgentController] real screen size: $_realScreenSize');
      } catch (e, st) {
        // Also covers Android in its current (input-only) phase - see
        // ScreenCaptureService.ensurePermission's doc comment. Screen
        // capture stays off for the rest of the session rather than
        // retrying and failing on every _screenshotTimer tick.
        _screenCaptureAvailable = false;
        debugPrint('[AgentController] screen permission failed: $e\n$st');
        _addMessage(ChatRole.system, 'Screen capture unavailable: $e');
      }

      // Triggers the Accessibility/Automation prompts up front (macOS)
      // or checks/opens the Accessibility settings screen (Android)
      // rather than waiting for whichever tool call Gemini happens to
      // make first - see the doc comment on ensureAccessibilityPermission
      // for why this is the only real mechanism available on either
      // platform. On Android specifically this can throw (the user has
      // to manually enable the service; there's no way to wait for that
      // synchronously), so it's surfaced as a system message rather
      // than failing the whole session start.
      try {
        await _system.ensureAccessibilityPermission();
      } catch (e) {
        _addMessage(ChatRole.system, '$e');
      }

      _wireLiveServiceEvents();
      await _live.connect(
        screenWidth: _realScreenSize?.width,
        screenHeight: _realScreenSize?.height,
      );

      if (audioAvailable) {
        try {
          _subs.add(_audio.micStream.listen((chunk) {
            if (!assistantSpeaking) _live.sendAudioChunk(chunk);
          }));
          await _audio.startListening();
        } catch (e, st) {
          audioAvailable = false;
          debugPrint('[AgentController] mic startListening failed: $e\n$st');
          _addMessage(
            ChatRole.system,
            'Could not start microphone capture ($e) - continuing in '
            'text-only mode. Full trace is in the terminal.',
          );
        }
      }

      if (_screenCaptureAvailable) {
        await _pushScreenshot();
      }

      if (!_live.isConnected) {
        // The socket already died (e.g. closed right after setup) before
        // we got here - don't lie and say the session is live.
        state = SessionState.error;
        lastError = 'Connection dropped before the session could start.';
        _addMessage(ChatRole.system, lastError!);
        notifyListeners();
        return;
      }

      if (_screenCaptureAvailable) {
        _screenshotTimer = Timer.periodic(
          AppConfig.screenshotInterval,
          (_) {
            // Skip the ambient frame entirely while Gemini is speaking (or
            // in the unmute grace period right after) - that's exactly
            // when socket contention with the outgoing audio stream shows
            // up as audible playback stutter, and the screen usually
            // hasn't changed mid-reply anyway.
            if (assistantSpeaking) return;
            _pushScreenshot(includeOverlay: false, ambient: true);
          },
        );
      }

      state = SessionState.live;
      _addMessage(
        ChatRole.system,
        audioAvailable ? 'Session started. Listening...' : 'Session started.',
      );
    } catch (e) {
      state = SessionState.error;
      lastError = e.toString();
      _addMessage(ChatRole.system, 'Failed to start: $e');
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _unmuteTimer?.cancel();
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    assistantSpeaking = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    await _audio.stopListening();
    await _audio.flushPlayback();
    await _live.disconnect();

    state = SessionState.idle;
    _addMessage(ChatRole.system, 'Session stopped.');
    notifyListeners();
  }

  void _wireLiveServiceEvents() {
    _subs.add(_live.audioOutput.listen((chunk) {
      // Mute the mic for as long as Gemini is speaking (see
      // assistantSpeaking's doc comment) - and cancel any pending
      // unmute, in case more audio starts arriving mid-grace-period.
      _unmuteTimer?.cancel();
      if (!assistantSpeaking) {
        assistantSpeaking = true;
        notifyListeners();
      }
      unawaited(_audio.playChunk(chunk));
    }));

    _subs.add(_live.textOutput.listen((text) {
      _addMessage(ChatRole.assistant, text);
    }));

    _subs.add(_live.turnComplete.listen((_) {
      // The server has stopped generating, but locally-buffered audio
      // is likely still playing out the speaker - wait a beat before
      // unmuting so that tail isn't picked back up by the mic either.
      _unmuteTimer?.cancel();
      _unmuteTimer = Timer(const Duration(milliseconds: 600), () {
        assistantSpeaking = false;
        notifyListeners();
      });
    }));

    _subs.add(_live.interrupted.listen((_) {
      // This is the *only* code path that stops Gemini's speech
      // mid-sentence - flushPlayback() is never called anywhere else
      // except AgentController.stop(). If the mic is muted whenever
      // Gemini is speaking (assistantSpeaking) and the server is set to
      // NO_INTERRUPTION, this shouldn't fire at all; logging it visibly
      // (not just in the debug console) makes it possible to confirm
      // whether that's actually still happening versus something else
      // (a dropped connection, a stalled tool call) looking similar.
      _addMessage(
        ChatRole.system,
        'Gemini\'s reply was interrupted by the server (unexpected with '
        'NO_INTERRUPTION enabled).',
      );
      unawaited(_audio.flushPlayback());
    }));

    _subs.add(_live.functionCalls.listen(_handleFunctionCall));

    _subs.add(_live.connectionState.listen((connected) {
      if (connected) {
        _addMessage(ChatRole.system, 'Gemini session setup complete.');
      } else if (state == SessionState.live) {
        state = SessionState.idle;
        _addMessage(ChatRole.system, 'Connection closed.');
        notifyListeners();
      }
    }));

    _subs.add(_live.errors.listen((error) {
      _addMessage(ChatRole.system, 'Gemini error: $error');
    }));
  }

  /// Pushes a fresh frame to Gemini. The grid/cursor overlay (a second
  /// full image) is only included when [includeOverlay] is true - the
  /// ambient periodic stream (see _screenshotTimer) sends the clean
  /// image alone to keep steady-state bandwidth down, since doubling
  /// every automatic frame turned out to be the main source of response
  /// lag once continuous streaming was reintroduced. The overlay is
  /// still sent for every explicit take_screenshot call and every
  /// move_mouse step, where the precise coordinate reference actually
  /// matters.
  ///
  /// [ambient] additionally shrinks the image itself
  /// (AppConfig.ambientScreenshotMaxWidth/Quality) - the periodic stream
  /// doesn't need to be pixel-precise, and a smaller/lossier frame means
  /// less to capture, encode and push over the same WebSocket carrying
  /// mic/speaker audio, where contention was showing up as audible
  /// playback stutter and slower turn-taking.
  Future<void> _pushScreenshot({
    bool includeOverlay = true,
    bool ambient = false,
  }) async {
    try {
      final shot = await _screen.captureJpeg(
        screenWidth: _realScreenSize?.width,
        screenHeight: _realScreenSize?.height,
        cursorX: _system.lastMousePosition?.x,
        cursorY: _system.lastMousePosition?.y,
        includeOverlay: includeOverlay,
        maxWidth: ambient ? AppConfig.ambientScreenshotMaxWidth : null,
        quality: ambient ? AppConfig.ambientScreenshotJpegQuality : null,
      );
      // Clean image first (nothing drawn over the real UI), then the
      // grid/cursor overlay as a separate reference image - see
      // ScreenCaptureService.captureJpeg for why these aren't merged.
      _live.sendImage(shot.bytes);
      if (shot.overlayBytes != null) {
        _live.sendImage(shot.overlayBytes!);
      }
    } catch (e) {
      _addMessage(ChatRole.system, 'Screenshot failed: $e');
    }
  }

  /// Moves the cursor to (targetX, targetY) in several small steps
  /// instead of one instant jump, sending Gemini a fresh frame (with the
  /// cursor marker) after each step - cliclick/xdotool teleport the
  /// cursor with nothing to "watch" otherwise, so this is what actually
  /// lets Gemini observe the cursor progressively approaching the target
  /// and react mid-movement, rather than only ever seeing a single
  /// before/after pair.
  Future<void> _moveMouseObserved(int targetX, int targetY) async {
    const steps = 2;
    final start = _system.lastMousePosition ?? (x: targetX, y: targetY);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final stepX = (start.x + (targetX - start.x) * t).round();
      final stepY = (start.y + (targetY - start.y) * t).round();
      await _system.moveMouse(stepX, stepY);
      await _pushScreenshot();
      if (i < steps) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  /// Gemini is told the real screen resolution directly (see
  /// GeminiLiveService.connect() / ToolDefinitions.screenResolutionInstruction)
  /// and asked to give move_mouse/click/drag coordinates in that same
  /// space, so no scaling is needed here - this just clamps to the real
  /// screen bounds as a safety net (keeps a wild coordinate from sending
  /// the cursor flying off-screen) and logs for diagnosis.
  (int, int) _toScreenCoords(int x, int y) {
    final real = _realScreenSize;
    if (real == null) {
      debugPrint('[AgentController] _toScreenCoords: no real size yet, ($x, $y) passed through');
      return (x, y);
    }
    final clamped = (x.clamp(0, real.width), y.clamp(0, real.height));
    debugPrint(
      '[AgentController] _toScreenCoords: gemini gave ($x, $y), real screen '
      'is $real, using $clamped',
    );
    return clamped;
  }

  Future<void> _handleFunctionCall(GeminiFunctionCall call) async {
    Map<String, dynamic> result;
    try {
      switch (call.name) {
        case 'take_screenshot':
          final shot = await _screen.captureJpeg(
            screenWidth: _realScreenSize?.width,
            screenHeight: _realScreenSize?.height,
            cursorX: _system.lastMousePosition?.x,
            cursorY: _system.lastMousePosition?.y,
          );
          _live.sendImage(shot.bytes);
          if (shot.overlayBytes != null) {
            _live.sendImage(shot.overlayBytes!);
          }
          result = {'result': 'screenshot captured and sent'};

        case 'click_element':
          final elName = call.args['name'] as String;
          final elProcess = (call.args['app'] as String?) ??
              await _system.frontmostProcessName();
          final clicked = await _system.clickElement(
            process: elProcess,
            searchText: elName,
          );
          if (clicked == null) {
            _logAction('click_element("$elName" in $elProcess) -> not found');
            result = {
              'error': 'No UI element matching "$elName" found in '
                  '"$elProcess". Fall back to find_ui_element or the '
                  'screenshot coordinate grid instead.',
            };
          } else {
            _logAction(
              'click_element("$elName" in $elProcess) -> clicked at '
              '(${clicked.x}, ${clicked.y})',
            );
            result = {
              'result': 'clicked',
              'x': clicked.x,
              'y': clicked.y,
            };
          }

        case 'find_ui_element':
          final name = call.args['name'] as String;
          final process = (call.args['app'] as String?) ??
              await _system.frontmostProcessName();
          final found = await _system.findUiElement(
            process: process,
            searchText: name,
          );
          if (found == null) {
            _logAction('find_ui_element("$name" in $process) -> not found');
            result = {
              'error': 'No UI element matching "$name" found in "$process". '
                  'Fall back to the screenshot coordinate grid instead.',
            };
          } else {
            _logAction(
              'find_ui_element("$name" in $process) -> (${found.x}, ${found.y})',
            );
            result = {'result': 'found', 'x': found.x, 'y': found.y};
          }

        case 'element_at_position':
          final ex = call.args['x'] as int;
          final ey = call.args['y'] as int;
          final atProcess = (call.args['app'] as String?) ??
              await _system.frontmostProcessName();
          final elementHere = await _system.elementAtPosition(
            process: atProcess,
            x: ex,
            y: ey,
          );
          if (elementHere == null) {
            _logAction('element_at_position($ex, $ey in $atProcess) -> nothing');
            result = {'result': 'nothing identified at that position'};
          } else {
            _logAction(
              'element_at_position($ex, $ey in $atProcess) -> '
              '${elementHere.role} "${elementHere.name}"',
            );
            result = {
              'result': 'found',
              'role': elementHere.role,
              'name': elementHere.name,
              'description': elementHere.description,
            };
          }

        case 'move_mouse':
          final (x, y) = _toScreenCoords(
            call.args['x'] as int,
            call.args['y'] as int,
          );
          await _moveMouseObserved(x, y);
          _logAction('move_mouse($x, $y)');
          result = {
            'result': 'moved - you were shown the cursor at each step '
                'along the way, ending at ($x, $y); check the final view '
                'before clicking',
          };

        case 'click':
          final rawX = call.args['x'] as int?;
          final rawY = call.args['y'] as int?;
          int? x;
          int? y;
          if (rawX != null && rawY != null) {
            (x, y) = _toScreenCoords(rawX, rawY);
          }
          final button = call.args['button'] as String? ?? 'left';
          final doubleClick = call.args['double_click'] as bool? ?? false;
          await _system.click(x: x, y: y, button: button, doubleClick: doubleClick);
          _logAction('click(x: $x, y: $y, button: $button, double: $doubleClick)');
          result = {'result': 'ok'};

        case 'drag':
          final (sx, sy) = _toScreenCoords(
            call.args['start_x'] as int,
            call.args['start_y'] as int,
          );
          final (ex, ey) = _toScreenCoords(
            call.args['end_x'] as int,
            call.args['end_y'] as int,
          );
          await _system.drag(sx, sy, ex, ey);
          _logAction('drag($sx,$sy -> $ex,$ey)');
          result = {'result': 'ok'};

        case 'type_text':
          final text = call.args['text'] as String;
          await _system.typeText(text);
          _logAction('type_text("$text")');
          result = {'result': 'ok'};

        case 'press_key':
          final key = call.args['key'] as String;
          await _system.pressKey(key);
          _logAction('press_key($key)');
          result = {'result': 'ok'};

        case 'scroll':
          final direction = call.args['direction'] as String;
          final amount = call.args['amount'] as int? ?? 3;
          await _system.scroll(direction, amount: amount);
          _logAction('scroll($direction, $amount)');
          result = {'result': 'ok'};

        default:
          result = {'error': 'Unknown tool: ${call.name}'};
      }
    } catch (e) {
      result = {'error': e.toString()};
      _logAction('${call.name} FAILED: $e');
    }

    _live.sendToolResponse(call.id, call.name, result);
    notifyListeners();
  }

  void sendTypedMessage(String text) {
    if (text.trim().isEmpty) return;
    _addMessage(ChatRole.user, text);
    _live.sendText(text);
  }

  void _addMessage(ChatRole role, String text) {
    messages.add(ChatMessage(role: role, text: text));
    notifyListeners();
  }

  void _logAction(String description) {
    actionLog.add('[${DateTime.now().toIso8601String()}] $description');
    _addMessage(ChatRole.action, description);
  }

  /// Releases mic/speaker/socket resources. Call and await this before
  /// the widget holding this controller is removed from the tree, then
  /// call [dispose] as usual.
  Future<void> shutdown() async {
    await stop();
    await _audio.dispose();
    await _live.dispose();
  }
}
