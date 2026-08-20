# AI as a Human

A Flutter app that puts Gemini in voice mode and lets it operate your
device like a person would: it listens, watches the screen, and acts —
moving the mouse, clicking, typing, and scrolling — while narrating what
it's doing out loud. Started as macOS/Linux/Windows desktop-only; there's
now an Android build too, though it currently only covers input control
(tap/type/click_element via Android's Accessibility Service) - Gemini
can't see the phone's screen yet, that's a separate follow-up (see the
Android setup section below).

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
  `toolCall` messages back. `contextWindowCompression.slidingWindow` is
  enabled in the setup - without it, Live sessions that send both audio
  and video/images (this app sends both) are capped at 2 minutes; with
  it, the server truncates old turns instead of ending the session.
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
  socket audio to the speakers, pushes a fresh screenshot on
  `AppConfig.screenshotInterval` (genuine screen sharing - Gemini sees
  a continuously updated view, not just a frame when it explicitly
  asks; `take_screenshot` still exists for forcing an immediate one),
  and dispatches each `toolCall` to `SystemControlService`, reporting
  the result back to Gemini so it can decide what to do next.

  This was tried once before and reverted for slowing responses down -
  a growing image added to every turn for the whole session. It's back
  because that's genuinely what was asked for (continuous screen
  sharing, not per-action snapshots), and the base screenshot quality
  is meaningfully better now (1280px/q80 vs the original 768px/q55), so
  the trade-off is worth re-evaluating. If responses feel too slow
  again, `AppConfig.screenshotInterval` is the first thing to lengthen
  (or drop back to on-demand-only by removing the periodic timer in
  `AgentController.start()`).

  Periodic frames send the clean screenshot only, not the grid overlay
  - `_pushScreenshot(includeOverlay: false)` on the timer. Once the
  coordinate-grid overlay (see "Coordinate grid + cursor marker" below)
  was reintroduced as a *second* full image per frame, sending it on
  every 2-second tick doubled steady-state image bandwidth on top of
  the continuous audio stream, which is what actually reintroduced the
  lag - not the periodic screenshots by themselves. The overlay still
  goes out for every `take_screenshot` call and every `move_mouse`
  step, where precise coordinates genuinely matter; the ambient stream
  is just for keeping up with what's currently on screen.

  Even a single-image periodic frame was still causing audible cuts in
  Gemini's speech, though - `ScreenCaptureService.captureJpeg`'s actual
  image work (PNG decode, resize, JPEG encode, and grid drawing when
  requested) is genuinely CPU-heavy, and it was running synchronously on
  the *same isolate* that receives Gemini's audio over the WebSocket and
  feeds it to the speaker. Every screenshot tick blocked that isolate for
  however long the image processing took, which is exactly what a
  mid-sentence audio stutter every couple of seconds looks like. That
  work now runs via `compute()` on a background isolate
  (`_processScreenshot`, a top-level function since isolate entry points
  can't be instance methods or closures) - the main isolate stays free to
  keep pumping audio in and out while a screenshot is being built.

  Still wasn't enough - the ambient stream sharing one WebSocket with
  mic/speaker audio meant every tick's outbound bytes were real
  contention on that connection regardless of which isolate produced
  them, showing up as both playback stutter and slower turn-taking right
  as the user stopped talking (the outgoing image competing with the
  final mic chunks / the server's response for the same pipe). Two more
  changes: `AppConfig.ambientScreenshotMaxWidth`/`ambientScreenshotJpegQuality`
  (800px/q55, vs 1280px/q80 for `take_screenshot`/`move_mouse`) shrink
  periodic frames specifically, since the ambient stream was never
  pixel-precise or used to aim clicks anyway; and the periodic timer now
  skips its tick entirely while `assistantSpeaking` is true, so no
  ambient frame is sent at all while Gemini's reply is actively being
  streamed and played - exactly when contention matters most.
  `screenshotInterval` was also lengthened from 2s to 3s.

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

### Coordinate mapping

Testing showed Gemini's `move_mouse`/`click`/`drag` coordinates aren't
reliably in any one fixed convention relative to the screenshot image -
neither raw screenshot pixels nor a consistent 0-1000 normalization
held up across calls. Rather than keep guessing which convention it's
implicitly using, the app now tells Gemini the real screen resolution
directly and asks it to give coordinates in that exact space:
`AgentController` fetches the real screen size *before* connecting and
passes it into `GeminiLiveService.connect(screenWidth:, screenHeight:)`,
which appends `ToolDefinitions.screenResolutionInstruction(w, h)` to
the system instruction - explicitly stating the exact pixel resolution
and asking for coordinates proportional to that, regardless of the
screenshot image's own dimensions. `_toScreenCoords()` now just clamps
to the real screen bounds as a safety net and logs anything it had to
clamp, rather than applying any scaling of its own.

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
`lib/models/tool_definitions.dart`: `take_screenshot`, `click_element`,
`find_ui_element`, `element_at_position`, `move_mouse`, `click`, `drag`,
`type_text`, `press_key`, `scroll`.

### Accessibility-based element lookup and clicking (macOS only)

Vision-based coordinate guessing (grid overlay, cursor marker, below)
helps, but it's still guessing. Three tools sidestep that entirely for
anything the Accessibility API can see:

- **`click_element`** (find AND click, in one step):
  `SystemControlService.clickElement()` searches the same way as
  `find_ui_element` below, but instead of reporting a position for
  Gemini to move_mouse/click toward, tells `System Events` to `click`
  the matched element reference directly - no coordinate math or
  `cliclick` involved. The OS moves the real cursor to the element
  itself and presses it, using its own exact knowledge of where that
  is. This is the most reliable way to click anything the Accessibility
  API can see, since there's no pixel estimate to be off by - the
  system prompt now has Gemini reach for this first, before
  `find_ui_element`/`move_mouse`/`click`, for anything with a visible
  name or label.
- **`find_ui_element`** (forward lookup - name to position, no click):
  `SystemControlService.findUiElement()` asks macOS's Accessibility API
  (via `System Events`) directly for the exact real-screen position of
  a UI element - a Dock icon, button, tab, menu item - by searching its
  name/description. Recurses through the target process's UI element
  tree (bounded to depth 5 / 400 elements visited, so it fails safely
  rather than hanging on a huge tree like a complex web page) and
  returns the center of the first name/description match. Now mainly a
  fallback for when `click_element` can't find a match but Gemini still
  wants an exact position to move_mouse toward manually.
- **`element_at_position`** (reverse lookup - position to identity):
  `SystemControlService.elementAtPosition()` asks what's at a given
  real-screen point, for verifying where move_mouse actually landed
  without needing to visually judge a screenshot. Recurses the same
  bounded way, but keeps the *smallest* element whose bounding box
  contains the point (depth 8 / 600 elements visited) rather than the
  first match, so a large container that happens to also overlap the
  point doesn't shadow the specific control actually there.

The OS already knows precisely where every element is; there's no
reason to guess when any of these work. The system prompt has Gemini
try click_element first for anything with a visible name or label,
falling back to find_ui_element (for a position to move_mouse toward)
and then the grid overlay only when both return no match.

Not implemented on Linux/Windows yet - all three throw
`UnsupportedError` there, which surfaces as a normal tool error Gemini
falls back from.

### Floating overlay UI (desktop) / full-screen UI (Android)

On macOS/Windows/Linux, `FloatingShell` (`lib/screens/floating_shell.dart`)
*is* the app - there's no separate full-size app window behind it. Using
`window_manager`, `main.dart` opens one small, frameless, transparent,
always-on-top window, and the whole UI lives inside it:

- **Collapsed** (the default): a small rounded pill just big enough for
  a Siri-style animated orb, a one-line status ("Listening...",
  "Speaking...", "Tap to start"), an expand ("more") button, and a close
  button. Draggable anywhere on screen via `DragToMoveArea`, since a
  frameless window has no OS-provided title bar to drag by.
- **Expanded** (tap the "more" button): the same window resizes
  (`windowManager.setSize(..., animate: true)`) into a taller panel
  revealing the full chat transcript and text input
  (`AssistantPanel`, shared with the mobile view below), with a
  collapse button to shrink back down.
- **Close**: stops the session and closes the window
  (`windowManager.close()`) - this is genuinely quitting the app, not
  just hiding it.

The orb itself (`lib/widgets/siri_orb.dart`, `SiriOrb`) is state-driven,
not real audio-amplitude-driven (no mic/playback level data is plumbed
up to it - state alone is simpler and keeps this reliable): a slow gray
"breathing" pulse when idle, amber when connecting, cyan/blue expanding
rings when listening, purple/pink faster rings when Gemini is actually
speaking (`AgentController.assistantSpeaking`) - `orbStateFor()` is the
one place that mapping happens, so every place an orb is rendered stays
in sync.

Android has no `window_manager` implementation, and a floating overlay
doesn't fit a phone's own full-screen UI paradigm anyway, so
`FloatingShell` renders a normal full-screen `Scaffold` with an `AppBar`
there instead (still showing the same animated orb next to the title) -
see `isFloatingDesktopOverlay` in `floating_shell.dart` for the branch.

None of the `window_manager` integration has been run - I have no
desktop GUI to actually launch and see this render here, the same
limitation as everything else native in this project. If the window
doesn't come up properly transparent/frameless on first try, check
`window_manager`'s own setup docs for any additional
`macos/Runner/MainFlutterWindow.swift` (or Windows/Linux equivalent)
changes it expects beyond what's already in this repo's `macos/`
setup instructions above.

### Coordinate grid + cursor marker

Testing showed the biggest source of misplaced clicks wasn't a
coordinate bug (screen size, image mirroring, and the click execution
were all verified correct) - it's that estimating a raw pixel position
with nothing to anchor against is genuinely hard for the model, even
for moderately-sized targets, and it had no way to check whether a
move_mouse actually landed correctly before committing to a click.

Every screenshot (`ScreenCaptureService.captureJpeg`) is sent as **two
separate images**, in order: the clean capture first, then a second
copy with a magenta grid and (if the cursor has moved) a cyan crosshair
drawn on it (`_drawCoordinateGrid` / `_drawCursorMarker`). These used to
be merged into one image, but gridlines/labels drawn directly over the
real screenshot can paint over the exact pixels of a small target -
actively hurting precision on the very targets that need it most.
Sending both lets Gemini identify the target precisely in the clean
image, then cross-reference the gridded one just for coordinates:

- The magenta grid, each line labeled with its real screen coordinate,
  lets Gemini read off nearby labels and interpolate an exact position
  instead of guessing blind.
- The cyan crosshair, at `SystemControlService.lastMousePosition` (the
  real coordinates last given to moveMouse/click/drag) and labeled
  `CURSOR (x,y)`, shows where the cursor actually is.

`move_mouse` doesn't jump the cursor straight to its target in one
instant hop either - `AgentController._moveMouseObserved()` moves it in
2 interpolated steps, sending a fresh frame (with the crosshair) after
each one - kept low since every step is a real screenshot round trip
and each one is also a point where a hung native call could stall the
whole session (see "Timeouts" below). This is the closest practical
equivalent to a live video
stream within the current architecture: cliclick/xdotool teleport the
cursor with nothing to watch by default, so this manufactures an actual
"travel" Gemini can observe frame-by-frame and react to mid-movement,
rather than only ever getting a single before/after pair. The system
prompt tells it to watch the cursor arrive and call move_mouse again to
correct if the final position isn't quite on target, repeating until it
is, before clicking.

### Timeouts

Testing surfaced the app freezing mid-action (stuck partway through a
multi-step move_mouse) with no recovery. Every real subprocess call
(`SystemControlService._run`, e.g. `cliclick`) and every native screen
capture (`ScreenCaptureService.captureJpeg`) is awaited with no timeout
by default - if one hangs (a permission dialog silently waiting for a
click, a stuck process), the tool call blocking on it, and the whole
session behind it, would wait forever with nothing recovering
automatically. Both now have an 8-second timeout and throw
`TimeoutException` instead of hanging, which `AgentController`'s
existing per-tool-call try/catch turns into a normal error result back
to Gemini - the session stays alive and responsive instead of freezing.

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
   <key>NSAppleEventsUsageDescription</key>
   <string>AI as a Human needs to send Apple Events to System Events to find and click on-screen elements accurately.</string>
   ```

   The `NSAppleEventsUsageDescription` key is required for `find_ui_element`
   and `element_at_position` (both drive `osascript`/"System Events" to
   query the Accessibility tree) to even prompt for the Automation
   permission they need. Without this key, macOS doesn't show a denial or
   any dialog at all - it just silently fails the Apple Event every time,
   which looks indistinguishable from "the app never asked." If you
   already ran the app once without this key, also check **System
   Settings → Privacy & Security → Automation** for a stale/missing
   "AI as a Human" entry with "System Events" unchecked, and re-run after
   adding the key if nothing is listed there yet.

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
   Recording**, enable the app there, and relaunch it.

   **Accessibility** and **Automation** permission (needed for every
   click/keystroke/UI lookup) work the same way, but there's no plugin
   API (permission_handler included) that can check or request either
   of them directly on macOS - the only real mechanism is to actually
   make a protected call and let the OS prompt on its own.
   `SystemControlService.ensureAccessibilityPermission()` does this
   proactively at session start (two deliberately harmless calls -
   listing System Events' processes for Automation, an empty keystroke
   for Accessibility) rather than waiting for whichever tool call
   Gemini happens to make first, which could be deep into a session and
   would otherwise read as the app randomly failing rather than a
   one-time setup step. If a dialog still doesn't appear (or was
   dismissed once), check **System Settings → Privacy & Security →
   Accessibility** and **→ Automation** manually - `SystemControlService`
   also recognizes denial-looking errors from real tool calls
   afterwards and prepends a hint pointing at both panels.

   If you add any other plugin to `pubspec.yaml` *after* already running
   `flutter create`, do a clean rebuild so CocoaPods links it in:
   ```
   flutter clean && flutter pub get && cd macos && pod install --repo-update && cd ..
   ```

3b. **Android only, current status: input control works, screen sharing
    does not yet.** Android has no shell/subprocess model at all (no
    `xdotool`/`cliclick` equivalent), so `SystemControlService` talks to
    a bundled `AccessibilityService` over a `MethodChannel` instead -
    the direct Android counterpart of macOS's System Events. Real
    screen capture needs `MediaProjection` plus a foreground service (a
    persistent notification, its own consent dialog, a whole separate
    video pipeline) - a substantially bigger piece of native code that
    isn't built yet, so for now Gemini can hear you and act
    (`click_element`, `find_ui_element`, `element_at_position`,
    `type_text`, `press_key`, `scroll`, `click`/`drag` by raw
    coordinate) but can't see the screen. `ScreenCaptureService`
    reports this clearly and `AgentController` just skips screenshot
    pushing for the rest of the session rather than failing.

    Unlike the desktop platforms, this needs real hand-written native
    code that `flutter create` won't regenerate, so `android/` is
    checked into this repo (see the comment in `.gitignore`) rather
    than excluded like `macos/`/`linux/`/`windows/`. Set it up once:

    1. Scaffold the platform folder if you don't have it yet:
       ```
       flutter create --platforms=android .
       ```
    2. Add to `android/app/src/main/AndroidManifest.xml` - the
       `RECORD_AUDIO` permission near the top, and the service
       declaration inside `<application>`:
       ```xml
       <uses-permission android:name="android.permission.RECORD_AUDIO" />
       ```
       ```xml
       <service
           android:name=".AiControlAccessibilityService"
           android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"
           android:exported="false">
           <intent-filter>
               <action android:name="android.accessibilityservice.AccessibilityService" />
           </intent-filter>
           <meta-data
               android:name="android.accessibilityservice"
               android:resource="@xml/accessibility_service_config" />
       </service>
       ```
    3. Create `android/app/src/main/res/xml/accessibility_service_config.xml`:
       ```xml
       <?xml version="1.0" encoding="utf-8"?>
       <accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
           android:accessibilityEventTypes="typeAllMask"
           android:accessibilityFeedbackType="feedbackGeneric"
           android:accessibilityFlags="flagDefault|flagRetrieveInteractiveWindows"
           android:canPerformGestures="true"
           android:canRetrieveWindowContent="true"
           android:description="@string/accessibility_service_description"
           android:notificationTimeout="100" />
       ```
       And add the referenced string to
       `android/app/src/main/res/values/strings.xml` (create it if it
       doesn't exist):
       ```xml
       <resources>
           <string name="accessibility_service_description">Lets AI as a Human find, tap, and type into on-screen elements on your behalf, the way a screen reader does.</string>
       </resources>
       ```
    4. Create `android/app/src/main/kotlin/<your/package/path>/AiControlAccessibilityService.kt`
       (same package/directory as the `MainActivity.kt` `flutter create`
       generated for you) - the Android equivalent of
       `system_control_service.dart`'s macOS branches: walks the
       accessibility node tree to find/click elements (bounded depth
       6 / 500 nodes, same idea as the macOS AppleScript's bounds) and
       dispatches real tap/swipe gestures.
       ```kotlin
       package com.example.ai_as_ahuman // replace with your actual applicationId

       import android.accessibilityservice.AccessibilityService
       import android.accessibilityservice.GestureDescription
       import android.graphics.Path
       import android.graphics.Rect
       import android.os.Bundle
       import android.view.accessibility.AccessibilityEvent
       import android.view.accessibility.AccessibilityNodeInfo

       class AiControlAccessibilityService : AccessibilityService() {

           companion object {
               var instance: AiControlAccessibilityService? = null
               private const val MAX_DEPTH = 6
               private const val MAX_NODES = 500
           }

           override fun onServiceConnected() {
               super.onServiceConnected()
               instance = this
           }

           override fun onDestroy() {
               super.onDestroy()
               instance = null
           }

           override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
           override fun onInterrupt() {}

           fun frontmostPackage(): String? = rootInActiveWindow?.packageName?.toString()

           fun screenSize(): Pair<Int, Int> {
               val metrics = resources.displayMetrics
               return Pair(metrics.widthPixels, metrics.heightPixels)
           }

           private class Counter(var count: Int = 0)

           private fun search(
               node: AccessibilityNodeInfo?,
               searchText: String,
               depth: Int,
               counter: Counter
           ): AccessibilityNodeInfo? {
               if (node == null || depth > MAX_DEPTH || counter.count > MAX_NODES) return null
               counter.count++
               val text = node.text?.toString() ?: ""
               val desc = node.contentDescription?.toString() ?: ""
               if (text.contains(searchText, ignoreCase = true) ||
                   desc.contains(searchText, ignoreCase = true)
               ) {
                   return node
               }
               for (i in 0 until node.childCount) {
                   val found = search(node.getChild(i), searchText, depth + 1, counter)
                   if (found != null) return found
               }
               return null
           }

           fun findElement(searchText: String): Map<String, Int>? {
               val root = rootInActiveWindow ?: return null
               val found = search(root, searchText, 0, Counter()) ?: return null
               val bounds = Rect()
               found.getBoundsInScreen(bounds)
               return mapOf("x" to bounds.centerX(), "y" to bounds.centerY())
           }

           fun clickElement(searchText: String): Map<String, Int>? {
               val root = rootInActiveWindow ?: return null
               val found = search(root, searchText, 0, Counter()) ?: return null
               val bounds = Rect()
               found.getBoundsInScreen(bounds)
               if (!found.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                   // Some elements (e.g. a text label inside a clickable
                   // parent) aren't directly clickable - walk up to the
                   // nearest clickable ancestor and click that instead.
                   var parent = found.parent
                   var depth = 0
                   while (parent != null && depth < MAX_DEPTH) {
                       if (parent.isClickable && parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                           break
                       }
                       parent = parent.parent
                       depth++
                   }
               }
               return mapOf("x" to bounds.centerX(), "y" to bounds.centerY())
           }

           private fun smallestAt(
               node: AccessibilityNodeInfo?,
               x: Int,
               y: Int,
               depth: Int,
               counter: Counter,
               best: Rect,
               bestNode: Array<AccessibilityNodeInfo?>
           ) {
               if (node == null || depth > 8 || counter.count > 600) return
               counter.count++
               val bounds = Rect()
               node.getBoundsInScreen(bounds)
               if (bounds.contains(x, y)) {
                   val area = bounds.width().toLong() * bounds.height().toLong()
                   val bestArea = best.width().toLong() * best.height().toLong()
                   if (bestNode[0] == null || area < bestArea) {
                       best.set(bounds)
                       bestNode[0] = node
                   }
                   for (i in 0 until node.childCount) {
                       smallestAt(node.getChild(i), x, y, depth + 1, counter, best, bestNode)
                   }
               }
           }

           fun elementAtPosition(x: Int, y: Int): Map<String, String>? {
               val root = rootInActiveWindow ?: return null
               val best = Rect()
               val bestNode = arrayOfNulls<AccessibilityNodeInfo>(1)
               smallestAt(root, x, y, 0, Counter(), best, bestNode)
               val node = bestNode[0] ?: return null
               return mapOf(
                   "role" to (node.className?.toString() ?: ""),
                   "name" to (node.text?.toString() ?: ""),
                   "description" to (node.contentDescription?.toString() ?: "")
               )
           }

           fun setTextOnFocusedNode(text: String): Boolean {
               val focused = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
               val args = Bundle()
               args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
               return focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
           }

           fun pressKey(key: String): Boolean {
               return when (key) {
                   "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
                   "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
                   "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
                   "enter" -> rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                       ?.performAction(AccessibilityNodeInfo.ACTION_IME_ENTER) ?: false
                   "tab" -> rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                       ?.performAction(AccessibilityNodeInfo.ACTION_NEXT_HTML_ELEMENT) ?: false
                   "delete", "backspace" -> {
                       val focused = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
                       val args = Bundle()
                       args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "")
                       focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                   }
                   else -> false
               }
           }

           fun tap(x: Int, y: Int) {
               val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
               val stroke = GestureDescription.StrokeDescription(path, 0, 50)
               dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
           }

           fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long) {
               val path = Path().apply {
                   moveTo(x1.toFloat(), y1.toFloat())
                   lineTo(x2.toFloat(), y2.toFloat())
               }
               val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
               dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
           }

           fun scroll(direction: String, amount: Int) {
               val metrics = resources.displayMetrics
               val cx = metrics.widthPixels / 2
               val cy = metrics.heightPixels / 2
               val delta = 200 * amount
               // Swiping is the inverse of the resulting scroll direction.
               val (x1, y1, x2, y2) = when (direction) {
                   "up" -> listOf(cx, cy - delta / 2, cx, cy + delta / 2)
                   "down" -> listOf(cx, cy + delta / 2, cx, cy - delta / 2)
                   "left" -> listOf(cx - delta / 2, cy, cx + delta / 2, cy)
                   else -> listOf(cx + delta / 2, cy, cx - delta / 2, cy)
               }
               swipe(x1, y1, x2, y2, 300)
           }
       }
       ```
    5. Edit `android/app/src/main/kotlin/<your/package/path>/MainActivity.kt`
       to register the `MethodChannel` the Dart side calls
       (`ai_as_ahuman/accessibility`) and route it to the service above:
       ```kotlin
       package com.example.ai_as_ahuman // replace with your actual applicationId

       import android.content.Intent
       import android.provider.Settings
       import android.text.TextUtils
       import io.flutter.embedding.android.FlutterActivity
       import io.flutter.embedding.engine.FlutterEngine
       import io.flutter.plugin.common.MethodChannel

       class MainActivity : FlutterActivity() {
           private val channelName = "ai_as_ahuman/accessibility"

           override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
               super.configureFlutterEngine(flutterEngine)
               MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
                   .setMethodCallHandler { call, result ->
                       val service = AiControlAccessibilityService.instance
                       when (call.method) {
                           "isServiceEnabled" -> result.success(isAccessibilityServiceEnabled())
                           "openAccessibilitySettings" -> {
                               startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                               result.success(null)
                           }
                           "screenSize" -> {
                               if (service == null) {
                                   result.error("NO_SERVICE", "Accessibility service not enabled", null)
                               } else {
                                   val (w, h) = service.screenSize()
                                   result.success(mapOf("width" to w, "height" to h))
                               }
                           }
                           "frontmostPackage" -> result.success(service?.frontmostPackage())
                           "findElement" -> result.success(
                               service?.findElement(call.argument<String>("searchText") ?: "")
                           )
                           "clickElement" -> result.success(
                               service?.clickElement(call.argument<String>("searchText") ?: "")
                           )
                           "elementAtPosition" -> result.success(
                               service?.elementAtPosition(
                                   call.argument<Int>("x") ?: 0,
                                   call.argument<Int>("y") ?: 0
                               )
                           )
                           "tap" -> {
                               service?.tap(call.argument<Int>("x") ?: 0, call.argument<Int>("y") ?: 0)
                               result.success(null)
                           }
                           "swipe" -> {
                               service?.swipe(
                                   call.argument<Int>("x1") ?: 0, call.argument<Int>("y1") ?: 0,
                                   call.argument<Int>("x2") ?: 0, call.argument<Int>("y2") ?: 0,
                                   (call.argument<Int>("durationMs") ?: 300).toLong()
                               )
                               result.success(null)
                           }
                           "scroll" -> {
                               service?.scroll(
                                   call.argument<String>("direction") ?: "down",
                                   call.argument<Int>("amount") ?: 3
                               )
                               result.success(null)
                           }
                           "setText" -> result.success(
                               service?.setTextOnFocusedNode(call.argument<String>("text") ?: "") ?: false
                           )
                           "pressKey" -> result.success(
                               service?.pressKey(call.argument<String>("key") ?: "") ?: false
                           )
                           else -> result.notImplemented()
                       }
                   }
           }

           private fun isAccessibilityServiceEnabled(): Boolean {
               val expectedComponent = "$packageName/.AiControlAccessibilityService"
               val enabledServices = Settings.Secure.getString(
                   contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
               ) ?: return false
               val splitter = TextUtils.SimpleStringSplitter(':')
               splitter.setString(enabledServices)
               while (splitter.hasNext()) {
                   if (splitter.next().equals(expectedComponent, ignoreCase = true)) return true
               }
               return false
           }
       }
       ```
    6. `android/app/build.gradle`'s `minSdkVersion`/`minSdk` needs to be
       at least **24** (Android 7.0) - `dispatchGesture` isn't available
       below that. Raise it if the generated default is lower.
    7. `flutter run -d <your-device-id>` (`flutter devices` to list a
       connected phone/emulator), then click "Start voice session" - the
       app will open Accessibility Settings for you the first time;
       find "AI as a Human" and enable it, then start the session again.

    None of this Kotlin has been compiled or run - I don't have an
    Android SDK/emulator to test with here, the same limitation as the
    macOS AppleScript earlier in this project. Expect to iterate on it
    against a real device/emulator.

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
  screens/floating_shell.dart      root widget - floating overlay (desktop) or full-screen (Android)
  widgets/
    siri_orb.dart                  animated Siri-style state-driven orb
    assistant_panel.dart           chat transcript + input bar (shared by both hosts above)
    chat_bubble.dart                one transcript message
```
