import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:record/record.dart';

import '../config/app_config.dart';

/// Wraps microphone capture and speaker playback of raw PCM16 audio,
/// matching the formats the Gemini Live API expects.
///
/// Uses `record` for the mic (it ships real implementations for every
/// desktop platform and requests its own permission) and
/// `mp_audio_stream` for playback (also fully cross-platform, but only
/// speaks Float32 samples, hence the PCM16 -> Float32 conversion below).
class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  final MpAudioStream _playback = getAudioStream();

  StreamSubscription<Uint8List>? _micSub;
  bool _playbackReady = false;
  bool _isRecording = false;

  final _micController = StreamController<Uint8List>.broadcast();

  /// Emits mic audio as it's captured, ready to hand straight to
  /// GeminiLiveService.sendAudioChunk.
  Stream<Uint8List> get micStream => _micController.stream;

  Future<void> init() async {
    debugPrint('[AudioService] init() start');

    final granted = await _recorder.hasPermission();
    debugPrint('[AudioService] mic permission granted: $granted');
    if (!granted) {
      throw StateError('Microphone permission denied.');
    }

    _playback.init(channels: 1, sampleRate: AppConfig.outputSampleRate);
    _playback.resume();
    _playbackReady = true;
    debugPrint('[AudioService] init() complete.');
  }

  Future<void> startListening() async {
    if (_isRecording) return;

    debugPrint(
      '[AudioService] starting mic stream: pcm16, mono, '
      '${AppConfig.inputSampleRate}Hz',
    );
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: AppConfig.inputSampleRate,
        numChannels: 1,
      ),
    );
    _micSub = stream.listen(_micController.add);
    _isRecording = true;
    debugPrint('[AudioService] mic stream started.');
  }

  Future<void> stopListening() async {
    if (!_isRecording) return;
    await _recorder.stop();
    await _micSub?.cancel();
    _micSub = null;
    _isRecording = false;
  }

  /// Converts Gemini's PCM16 (little-endian, mono) chunk to the Float32
  /// samples mp_audio_stream expects and queues it for playback.
  Future<void> playChunk(Uint8List pcm16) async {
    if (!_playbackReady) return;
    final byteData = ByteData.sublistView(pcm16);
    final sampleCount = pcm16.length ~/ 2;
    final samples = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    _playback.push(samples);
  }

  /// Called when Gemini reports the user interrupted it: drop whatever
  /// audio is still queued so playback stops immediately.
  Future<void> flushPlayback() async {
    if (!_playbackReady) return;
    // mp_audio_stream has no explicit "clear buffer" call - reinitializing
    // is the pragmatic way to drop whatever's still queued.
    _playback.uninit();
    _playback.init(channels: 1, sampleRate: AppConfig.outputSampleRate);
    _playback.resume();
  }

  Future<void> dispose() async {
    await stopListening();
    _recorder.dispose();
    if (_playbackReady) {
      _playback.uninit();
      _playbackReady = false;
    }
    await _micController.close();
  }
}
