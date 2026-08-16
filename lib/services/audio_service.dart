import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/app_config.dart';

/// Wraps microphone capture and speaker playback of raw PCM16 audio,
/// matching the formats the Gemini Live API expects.
class AudioService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  StreamController<Uint8List>? _micStreamController;
  bool _recorderOpen = false;
  bool _playerOpen = false;
  bool _isRecording = false;
  bool _isPlaying = false;

  final _micController = StreamController<Uint8List>.broadcast();

  /// Emits mic audio as it's captured, ready to hand straight to
  /// GeminiLiveService.sendAudioChunk.
  Stream<Uint8List> get micStream => _micController.stream;

  Future<void> init() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw StateError('Microphone permission denied.');
    }
    await _recorder.openRecorder();
    await _player.openPlayer();
    _recorderOpen = true;
    _playerOpen = true;
    await _player.setSubscriptionDuration(const Duration(milliseconds: 100));
  }

  Future<void> startListening() async {
    if (!_recorderOpen || _isRecording) return;

    _micStreamController = StreamController<Uint8List>();
    _micStreamController!.stream.listen((data) {
      _micController.add(data);
    });

    await _recorder.startRecorder(
      toStream: _micStreamController!.sink,
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: AppConfig.inputSampleRate,
    );
    _isRecording = true;
  }

  Future<void> stopListening() async {
    if (!_isRecording) return;
    await _recorder.stopRecorder();
    await _micStreamController?.close();
    _micStreamController = null;
    _isRecording = false;
  }

  Future<void> startPlayback() async {
    if (!_playerOpen || _isPlaying) return;
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: AppConfig.outputSampleRate,
      interleaved: true,
      bufferSize: 4096,
    );
    _isPlaying = true;
  }

  Future<void> playChunk(Uint8List pcm16) async {
    if (!_isPlaying) await startPlayback();
    await _player.feedUint8FromStream(pcm16);
  }

  /// Called when Gemini reports the user interrupted it: drop whatever
  /// audio is still queued so playback stops immediately.
  Future<void> flushPlayback() async {
    if (!_isPlaying) return;
    await _player.stopPlayer();
    _isPlaying = false;
  }

  Future<void> dispose() async {
    await stopListening();
    await flushPlayback();
    if (_recorderOpen) await _recorder.closeRecorder();
    if (_playerOpen) await _player.closePlayer();
    await _micController.close();
  }
}
