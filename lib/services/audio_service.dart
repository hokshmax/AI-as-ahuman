import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_macos_permissions/flutter_macos_permissions.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;
import 'package:permission_handler/permission_handler.dart';

import '../config/app_config.dart';

/// Wraps microphone capture and speaker playback of raw PCM16 audio,
/// matching the formats the Gemini Live API expects.
class AudioService {
  // Verbose logLevel makes flutter_sound print every native call it
  // makes and every event it gets back, which is the only way to see
  // *where* a recorder/player call is actually failing on-device.
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder(logLevel: Level.trace);
  final FlutterSoundPlayer _player = FlutterSoundPlayer(logLevel: Level.trace);

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
    debugPrint('[AudioService] init() start on ${Platform.operatingSystem}');

    // permission_handler only implements Android, iOS, web and Windows -
    // there's no macOS or Linux backend, so calling it there throws
    // MissingPluginException. macOS gets its own explicit request below;
    // on Linux there's no permission model to request against at all.
    if (Platform.isWindows) {
      debugPrint('[AudioService] requesting mic permission via permission_handler');
      final status = await Permission.microphone.request();
      debugPrint('[AudioService] permission_handler mic status: $status');
      if (!status.isGranted) {
        throw StateError('Microphone permission denied.');
      }
    } else if (Platform.isMacOS) {
      debugPrint('[AudioService] requesting mic permission via flutter_macos_permissions');
      final status = await FlutterMacosPermissions.requestMicrophone();
      debugPrint('[AudioService] flutter_macos_permissions mic status: $status');
      if (!status.isGranted) {
        throw StateError(
          'Microphone permission denied. Grant it under System Settings '
          '-> Privacy & Security -> Microphone and restart the app.',
        );
      }
    }

    debugPrint('[AudioService] opening recorder...');
    await _recorder.openRecorder();
    debugPrint('[AudioService] recorder open.');

    debugPrint('[AudioService] opening player...');
    await _player.openPlayer();
    debugPrint('[AudioService] player open.');

    _recorderOpen = true;
    _playerOpen = true;
    await _player.setSubscriptionDuration(const Duration(milliseconds: 100));
    debugPrint('[AudioService] init() complete.');
  }

  Future<void> startListening() async {
    if (!_recorderOpen || _isRecording) return;

    _micStreamController = StreamController<Uint8List>();
    _micStreamController!.stream.listen((data) {
      _micController.add(data);
    });

    debugPrint(
      '[AudioService] starting recorder: pcm16, mono, '
      '${AppConfig.inputSampleRate}Hz',
    );
    await _recorder.startRecorder(
      toStream: _micStreamController!.sink,
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: AppConfig.inputSampleRate,
    );
    debugPrint('[AudioService] recorder started.');
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
    if (!_playerOpen) return;
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
