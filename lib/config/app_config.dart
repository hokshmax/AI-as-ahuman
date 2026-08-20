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
  /// each round trip small. Testing showed 768px/q55 was too lossy for
  /// precisely locating small targets (Dock icons, toolbar buttons);
  /// trading some speed for clearer images. Used for take_screenshot and
  /// every move_mouse step, where precise coordinates actually matter.
  static const int screenshotMaxWidth = 1280;
  static const int screenshotJpegQuality = 80;

  /// The periodic ambient stream (AgentController._screenshotTimer) only
  /// needs to be good enough to keep Gemini roughly aware of what's on
  /// screen, not pixel-precise - it never has the coordinate grid, and
  /// isn't used to aim clicks. Sending it at full size/quality shared
  /// the same WebSocket as mic/speaker audio and was measurably
  /// contending with it: audible stutters in Gemini's speech, and
  /// noticeably slower turn-taking right as the user stopped talking.
  /// Smaller/lossier ambient frames mean less to capture, encode, and
  /// push over the wire on every tick.
  static const int ambientScreenshotMaxWidth = 800;
  static const int ambientScreenshotJpegQuality = 55;

  /// How often a fresh screenshot is pushed automatically, so Gemini has
  /// a continuously updated view of the screen - genuine screen sharing
  /// rather than only seeing a frame when it explicitly asks for one.
  static const Duration screenshotInterval = Duration(seconds: 3);
}
