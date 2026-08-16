# AI as a Human

A Flutter desktop app that puts Gemini in voice mode and lets it operate
your computer like a person would: it listens, watches your screen, and
acts — moving the mouse, clicking, typing, and scrolling — while
narrating what it's doing out loud.

## How it works

```
 mic  ──PCM16──▶ GeminiLiveService ──WebSocket──▶ Gemini Live API
speaker ◀──PCM16── (audio out)                         │
                                                          │ tool calls
                                                          ▼
                              AgentController ──▶ SystemControlService
                                     │                (mouse/keyboard)
                                     ▼
                          ScreenCaptureService ──screenshots──▶ Gemini
```

- **`GeminiLiveService`** (`lib/services/gemini_live_service.dart`) speaks
  the Gemini Live ("BidiGenerateContent") WebSocket protocol: it sends
  the session setup (model, system instruction, tool declarations),
  streams mic audio and screenshots in, and receives audio, text, and
  `toolCall` messages back. Automatic (server-side) voice activity
  detection is disabled in the setup - see "Push-to-talk" below.
- **`AudioService`** captures the microphone (`record`, streaming
  PCM16) and plays Gemini's spoken replies back (`mp_audio_stream`,
  which speaks Float32 - `AudioService` converts each incoming PCM16
  chunk before pushing it).
- **`ScreenCaptureService`** grabs the screen with `screen_capturer`,
  downsizes and JPEG-encodes it so round trips stay fast.
- **`SystemControlService`** turns tool calls into real input events. It
  shells out to the best native automation tool per OS (see below) since
  there is no single cross-platform Dart API for synthetic input.
- **`AgentController`** is the glue: it wires mic audio to the socket,
  socket audio to the speakers, sends one screenshot to establish
  context at session start (Gemini requests further ones itself via the
  `take_screenshot` tool as needed - continuously pushing one on a timer
  was adding a growing image to every turn and made responses slow), and
  dispatches each `toolCall` to `SystemControlService`, reporting the
  result back to Gemini so it can decide what to do next.

### Automatic self-interruption prevention

Listening is always-on - no push-to-talk button. The mic is only ever
*muted automatically* for as long as Gemini's own reply is playing
(`AgentController.assistantSpeaking`, set the instant audio starts
arriving and cleared ~600ms after `turnComplete`, to cover the tail
still draining out of the speaker). Mic audio is dropped client-side
during that window instead of being forwarded.

This exists because of a real bug you'll otherwise hit constantly: with
the Mac's built-in speaker and mic (no headphones), Gemini's own voice
leaks back into the mic, and the Live API's automatic voice-activity
detection reads that echo as you interrupting it, cutting Gemini off
mid-sentence after a word or two. Client-side muting alone is a race
against the network, though - a chunk of mic audio sent moments before
`assistantSpeaking` flips can still land server-side just as Gemini
starts talking. So `gemini_live_service.dart`'s setup also sets
`realtimeInputConfig.activityHandling` to `NO_INTERRUPTION`, which
tells the *server* to never cut a reply short due to detected mic
activity, closing that race entirely - Gemini now always finishes what
it's saying. The trade-off: you can no longer verbally barge in and cut
it off mid-sentence either; you have to wait for it to finish (or use
the text box, which isn't affected). Switch back to
`START_OF_ACTIVITY_INTERRUPTS` (and remove the `if (!assistantSpeaking)`
guard around `_live.sendAudioChunk` in `AgentController.start()`) if
you'd rather have true barge-in and are on headphones where the echo
problem doesn't apply.

### Coordinate mapping (screenshot pixels -> real screen)

Gemini's `move_mouse`/`click`/`drag` coordinates are relative to the
screenshot it was last shown, which is downscaled from the real screen
(`AppConfig.screenshotMaxWidth`). `AgentController._toScreenCoords()`
scales those back up using the ratio between the last screenshot's
exact pixel size and the real screen size.

That real screen size is deliberately fetched via
`SystemControlService.screenSize()` - which queries it through the
*same* tool that performs clicks (`xdotool getdisplaygeometry` on
Linux, `osascript`/System Events desktop bounds on macOS, WinForms
`Screen.PrimaryScreen.Bounds` on Windows) - rather than a separate
plugin. A separate screen-info plugin can silently report a different
unit (e.g. physical Retina pixels vs. the logical points `cliclick`
actually clicks in), which produces exactly the "consistently
scaled/offset" symptom this was built to avoid.

Known limitation: this assumes a single display. On a multi-monitor
setup, `screen_capturer`'s capture region and `screenSize()`'s "primary
display" may not agree (e.g. if capture spans all displays), which
would reintroduce coordinate drift - not yet handled.

The tools Gemini can call are declared in
`lib/models/tool_definitions.dart`: `take_screenshot`, `move_mouse`,
`click`, `drag`, `type_text`, `press_key`, `scroll`.

## Testing in GitHub Codespaces

This repo includes a `.devcontainer` so you can try the app without a
local Flutter install:

1. On GitHub, open **Code → Codespaces → Create codespace on
   `claude/flutter-gemini-voice-screen-control-7wmhny`**.
2. Wait for `postCreateCommand` to finish — it installs the Flutter SDK,
   Linux desktop build tooling, and `xdotool`, then runs `flutter pub get`.
3. Open the forwarded port **6080** (noVNC) in your browser — that's a
   real virtual desktop running inside the codespace, so `xdotool` has
   an actual screen to move the mouse and click on.
4. In the codespace terminal:
   ```
   flutter run -d linux --dart-define=GEMINI_API_KEY=your_key_here
   ```
   The app window will appear inside the noVNC desktop tab.

Codespaces gives you a full X11 session, so mouse/click/screenshot tools
genuinely work end-to-end there — it's not just a headless build check.
Microphone capture, however, has no hardware to attach to in a container,
so voice input won't work in Codespaces; use the "Type instead of
talking..." box in the UI to drive a session instead.

## Setup (local machine)

1. Scaffold the native platform folders (not checked into this repo —
   see `.gitignore`):

   ```
   flutter create --platforms=linux,macos,windows .
   ```

2. Install the OS-level automation tool this app shells out to:

   | Platform | Tool | Install |
   |---|---|---|
   | Linux | `xdotool` | `sudo apt install xdotool` |
   | macOS | `cliclick` | `brew install cliclick` (keyboard uses built-in AppleScript) |
   | Windows | none | built-in PowerShell + user32.dll, no install needed |

3. **macOS only:** `flutter create` sandboxes the app by default (App
   Sandbox). That's incompatible with what this app does — spawning
   `cliclick`/`osascript` subprocesses for mouse/keyboard control and
   capturing the whole screen both require capabilities a sandboxed app
   isn't allowed. Real automation tools on macOS (Hammerspoon,
   BetterTouchTool, etc.) all ship unsandboxed for the same reason.

   Open `macos/Runner/DebugProfile.entitlements` **and**
   `macos/Runner/Release.entitlements` and turn the sandbox flag off:
   ```xml
   <key>com.apple.security.app-sandbox</key>
   <false/>
   <key>com.apple.security.network.client</key>
   <true/>
   <key>com.apple.security.device.audio-input</key>
   <true/>
   ```

   And add to `macos/Runner/Info.plist`:
   ```xml
   <key>NSMicrophoneUsageDescription</key>
   <string>AI as a Human needs the microphone to talk to Gemini.</string>
   ```

   Mic permission is requested by the `record` package itself
   (`AudioRecorder.hasPermission()` in `AudioService.init()`) — it
   ships real implementations for every desktop platform, no separate
   permission plugin needed. Screen Recording permission on macOS is
   requested explicitly via `flutter_macos_permissions`
   (`ScreenCaptureService.ensurePermission()`), since `screen_capturer`
   doesn't trigger that consent dialog on its own. macOS will show its
   native consent dialogs the first time you click "Start voice
   session". If you don't get a dialog and capture still fails,
   permission may have been silently denied already; check **System
   Settings → Privacy & Security → Microphone** and **→ Screen
   Recording**, enable the app there, and relaunch it. The first
   click/keystroke may similarly need **Accessibility** permission
   granted the same way (macOS prompts for it the first time
   `cliclick`/`osascript` actually runs).

   If you add any other plugin to `pubspec.yaml` *after* already running
   `flutter create`, do a clean rebuild so CocoaPods links it in:
   ```
   flutter clean && flutter pub get && cd macos && pod install --repo-update && cd ..
   ```

4. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).

5. Run:

   ```
   flutter pub get
   flutter run -d linux --dart-define=GEMINI_API_KEY=your_key_here
   ```

   (swap `-d linux` for `-d macos` / `-d windows` as needed — mobile and
   web targets can't drive the OS mouse/keyboard, so this app is
   desktop-only.)

### If the app connects but Gemini never replies

Google renames and rotates Live API model IDs fairly often, and access
varies by API key/region. The default here is currently
`gemini-3.1-flash-live-preview` (Gemini 3.1 Flash Live). If the session
opens (status shows "Live") but you never get `"Gemini session setup
complete."` in the transcript, you'll see a clear timeout error after
10s instead of silence — it means that default isn't valid for your
key. Override it:
```
flutter run -d macos --dart-define=GEMINI_API_KEY=your_key_here \
  --dart-define=GEMINI_MODEL=models/gemini-live-2.5-flash-preview
```
Check [Google AI Studio](https://aistudio.google.com/) or the
[Live API docs](https://ai.google.dev/gemini-api/docs/live-api) for the
current model ID your key has access to if that one also fails.

## Safety

Giving a model direct control of your mouse and keyboard is inherently
risky. This project mitigates that with:

- A system prompt (`ToolDefinitions.systemInstruction`) that tells
  Gemini to narrate before acting, take small verifiable steps, and
  explicitly confirm with the user before anything destructive
  (deleting files, payments, messages, security settings).
- A visible, timestamped action log of every real input event the app
  sent, so you can always see exactly what happened.

None of this is a hard technical guarantee — treat this as a prototype,
run it in a sandboxed or low-stakes environment first, and keep an eye
on the screen while a session is live. macOS and Windows will prompt for
Accessibility / input-simulation permissions the first time the app
tries to control the mouse or keyboard; on Linux `xdotool` needs an X11
(or XWayland) session.

## Project layout

```
lib/
  config/app_config.dart          endpoint, model, sample rates, API key
  models/
    chat_message.dart             transcript entry
    tool_definitions.dart         Gemini function-calling schema + system prompt
  services/
    gemini_live_service.dart      Live API WebSocket client
    audio_service.dart            mic capture / speaker playback (PCM16)
    screen_capture_service.dart   screenshot capture + downscale
    system_control_service.dart  mouse/keyboard automation per OS
    agent_controller.dart        wires everything together
  screens/chat_screen.dart        voice session UI
  widgets/                        chat bubble, status dot
```
