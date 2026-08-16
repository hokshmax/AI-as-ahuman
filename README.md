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
  `toolCall` messages back.
- **`AudioService`** captures the microphone and plays Gemini's spoken
  replies as raw 16-bit PCM, using `flutter_sound`.
- **`ScreenCaptureService`** grabs the screen with `screen_capturer`,
  downsizes and JPEG-encodes it so round trips stay fast.
- **`SystemControlService`** turns tool calls into real input events. It
  shells out to the best native automation tool per OS (see below) since
  there is no single cross-platform Dart API for synthetic input.
- **`AgentController`** is the glue: it wires mic audio to the socket,
  socket audio to the speakers, pushes a screenshot on a timer plus
  on-demand, and dispatches each `toolCall` to `SystemControlService`,
  reporting the result back to Gemini so it can decide what to do next.

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

   The first time the app actually takes a screenshot, macOS will
   prompt for **Screen Recording** permission (or silently fail until
   you grant it yourself under **System Settings → Privacy & Security →
   Screen Recording** and relaunch the app). The first click/keystroke
   may similarly need **Accessibility** permission granted the same way.

   If you add `permission_handler` (or any plugin) to `pubspec.yaml`
   *after* already running `flutter create`, also do a clean rebuild so
   CocoaPods links it in:
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
