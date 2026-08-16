import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import '../models/tool_definitions.dart';

/// A function call Gemini asked the client to perform on its behalf.
class GeminiFunctionCall {
  GeminiFunctionCall({required this.id, required this.name, required this.args});

  final String id;
  final String name;
  final Map<String, dynamic> args;
}

/// Thin client for the Gemini Live ("BidiGenerateContent") API: a
/// long-lived WebSocket carrying streamed audio in both directions plus
/// out-of-band tool calls.
class GeminiLiveService {
  GeminiLiveService({String? apiKey}) : _apiKey = apiKey ?? AppConfig.geminiApiKey;

  final String _apiKey;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _setupComplete = false;

  final _audioOutController = StreamController<Uint8List>.broadcast();
  final _textController = StreamController<String>.broadcast();
  final _functionCallController = StreamController<GeminiFunctionCall>.broadcast();
  final _turnCompleteController = StreamController<void>.broadcast();
  final _interruptedController = StreamController<void>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  /// Raw PCM16 audio chunks spoken by the model.
  Stream<Uint8List> get audioOutput => _audioOutController.stream;

  /// Any text Gemini produced alongside/instead of audio (rare in audio
  /// mode, but useful for transcript logging).
  Stream<String> get textOutput => _textController.stream;

  /// Tools Gemini wants executed on the screen.
  Stream<GeminiFunctionCall> get functionCalls => _functionCallController.stream;

  Stream<void> get turnComplete => _turnCompleteController.stream;

  /// Fired when the user starts talking over the model; playback should
  /// stop immediately.
  Stream<void> get interrupted => _interruptedController.stream;

  Stream<bool> get connectionState => _connectionStateController.stream;

  bool get isConnected => _setupComplete;

  Future<void> connect() async {
    if (_apiKey.isEmpty) {
      throw StateError(
        'Missing Gemini API key. Run with '
        '--dart-define=GEMINI_API_KEY=your_key',
      );
    }

    final uri = Uri.parse('${AppConfig.liveEndpoint}?key=$_apiKey');
    _channel = WebSocketChannel.connect(uri);
    await _channel!.ready;

    _subscription = _channel!.stream.listen(
      _handleMessage,
      onDone: () {
        _setupComplete = false;
        _connectionStateController.add(false);
      },
      onError: (Object error) {
        _setupComplete = false;
        _connectionStateController.add(false);
      },
    );

    _send({
      'setup': {
        'model': AppConfig.geminiModel,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
        },
        'systemInstruction': {
          'parts': [
            {'text': ToolDefinitions.systemInstruction},
          ],
        },
        'tools': [
          {'functionDeclarations': ToolDefinitions.declarations},
        ],
      },
    });
  }

  void _handleMessage(dynamic raw) {
    final Map<String, dynamic> message =
        jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>))
            as Map<String, dynamic>;

    if (message.containsKey('setupComplete')) {
      _setupComplete = true;
      _connectionStateController.add(true);
      return;
    }

    final serverContent = message['serverContent'] as Map<String, dynamic>?;
    if (serverContent != null) {
      if (serverContent['interrupted'] == true) {
        _interruptedController.add(null);
      }

      final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
      final parts = modelTurn?['parts'] as List<dynamic>?;
      if (parts != null) {
        for (final part in parts) {
          final p = part as Map<String, dynamic>;
          final inlineData = p['inlineData'] as Map<String, dynamic>?;
          if (inlineData != null &&
              (inlineData['mimeType'] as String? ?? '').startsWith('audio/')) {
            _audioOutController.add(base64Decode(inlineData['data'] as String));
          }
          final text = p['text'] as String?;
          if (text != null && text.isNotEmpty) {
            _textController.add(text);
          }
        }
      }

      if (serverContent['turnComplete'] == true) {
        _turnCompleteController.add(null);
      }
      return;
    }

    final toolCall = message['toolCall'] as Map<String, dynamic>?;
    if (toolCall != null) {
      final calls = toolCall['functionCalls'] as List<dynamic>? ?? [];
      for (final call in calls) {
        final c = call as Map<String, dynamic>;
        _functionCallController.add(
          GeminiFunctionCall(
            id: c['id'] as String? ?? '',
            name: c['name'] as String,
            args: (c['args'] as Map<String, dynamic>?) ?? const {},
          ),
        );
      }
    }
  }

  /// Streams one chunk of mic audio (16-bit PCM, mono, 16kHz) to Gemini.
  void sendAudioChunk(Uint8List pcm16) {
    if (!_setupComplete) return;
    _send({
      'realtimeInput': {
        'mediaChunks': [
          {
            'mimeType': 'audio/pcm;rate=${AppConfig.inputSampleRate}',
            'data': base64Encode(pcm16),
          },
        ],
      },
    });
  }

  /// Pushes a screenshot (JPEG) into the session so Gemini can see the
  /// screen without waiting for the next take_screenshot call to round-trip.
  void sendImage(Uint8List jpegBytes) {
    if (!_setupComplete) return;
    _send({
      'realtimeInput': {
        'mediaChunks': [
          {
            'mimeType': 'image/jpeg',
            'data': base64Encode(jpegBytes),
          },
        ],
      },
    });
  }

  /// Sends a plain text turn, e.g. for typed input alongside voice.
  void sendText(String text) {
    if (!_setupComplete) return;
    _send({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'turnComplete': true,
      },
    });
  }

  /// Reports the result of a tool call back to Gemini so it can decide
  /// on the next action.
  void sendToolResponse(String callId, String name, Map<String, dynamic> result) {
    if (!_setupComplete) return;
    _send({
      'toolResponse': {
        'functionResponses': [
          {
            'id': callId,
            'name': name,
            'response': result,
          },
        ],
      },
    });
  }

  void _send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    _setupComplete = false;
  }

  Future<void> dispose() async {
    await disconnect();
    await _audioOutController.close();
    await _textController.close();
    await _functionCallController.close();
    await _turnCompleteController.close();
    await _interruptedController.close();
    await _connectionStateController.close();
  }
}
