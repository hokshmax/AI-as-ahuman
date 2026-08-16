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
        debugPrint('[AgentController] screen permission failed: $e\n$st');
        _addMessage(ChatRole.system, 'Screen capture unavailable: $e');
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

      // One screenshot to establish context; after that Gemini decides
      // when it needs a fresh look via the take_screenshot tool instead
      // of us pushing one on a timer - that was adding a growing image
      // to every turn for the whole session and was the main source of
      // slow responses.
      await _pushScreenshot();

      if (!_live.isConnected) {
        // The socket already died (e.g. closed right after setup) before
        // we got here - don't lie and say the session is live.
        state = SessionState.error;
        lastError = 'Connection dropped before the session could start.';
        _addMessage(ChatRole.system, lastError!);
        notifyListeners();
        return;
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

  Future<void> _pushScreenshot() async {
    try {
      final shot = await _screen.captureJpeg(
        screenWidth: _realScreenSize?.width,
        screenHeight: _realScreenSize?.height,
        cursorX: _system.lastMousePosition?.x,
        cursorY: _system.lastMousePosition?.y,
      );
      _live.sendImage(shot.bytes);
    } catch (e) {
      _addMessage(ChatRole.system, 'Screenshot failed: $e');
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
          result = {'result': 'screenshot captured and sent'};

        case 'move_mouse':
          final (x, y) = _toScreenCoords(
            call.args['x'] as int,
            call.args['y'] as int,
          );
          await _system.moveMouse(x, y);
          _logAction('move_mouse($x, $y)');
          // Automatically follow every move with an updated view marking
          // the new cursor position, instead of relying on a separate
          // take_screenshot call - closer to how a person just sees
          // their cursor move rather than having to deliberately check.
          await _pushScreenshot();
          result = {
            'result': 'moved - an updated screenshot with the new cursor '
                'position was sent, check it before clicking',
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
