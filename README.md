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

## Setup

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

3. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).

4. Run:

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
