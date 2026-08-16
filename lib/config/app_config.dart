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
    defaultValue: 'models/gemini-2.0-flash-live-001',
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

  /// How often to push a fresh screenshot into the session so Gemini
  /// keeps an up-to-date view of the screen even without asking for one.
  static const Duration screenshotInterval = Duration(seconds: 3);

  /// Screenshots are downscaled before upload to keep turnaround fast.
  static const int screenshotMaxWidth = 1024;
}
