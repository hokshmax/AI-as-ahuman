/// Runtime configuration for the Gemini Live connection.
///
/// The API key is never hardcoded. Pass it at launch with:
///   flutter run --dart-define=GEMINI_API_KEY=your_key_here
class AppConfig {
  AppConfig._();

  static const String geminiApiKey =
      String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

  /// Live API model IDs shift around and access varies by account/region,
  /// so this is overridable without a code change:
  ///   flutter run --dart-define=GEMINI_MODEL=models/gemini-live-2.5-flash-preview
  static const String geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'models/gemini-3.1-flash-live-preview',
  );

  /// How long to wait for the server's setupComplete before giving up and
  /// reporting an error - Gemini stays silent rather than erroring when
  /// the requested model isn't valid/accessible for the API key in use.
  static const Duration setupTimeout = Duration(seconds: 10);

  static const String liveEndpoint =
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  /// Gemini Live expects 16-bit PCM mono audio in from the mic...
  static const int inputSampleRate = 16000;

  /// ...and streams 16-bit PCM mono audio back at this rate.
  static const int outputSampleRate = 24000;

  /// Screenshots are downscaled and compressed before upload to keep
  /// each round trip small - Gemini asks for a fresh one via the
  /// take_screenshot tool whenever it actually needs to look, rather
  /// than one being pushed continuously on a timer. Testing showed
  /// 768px/q55 was too lossy for precisely locating small targets (Dock
  /// icons, toolbar buttons); trading some speed for clearer images.
  static const int screenshotMaxWidth = 1280;
  static const int screenshotJpegQuality = 80;
}
