import 'dart:async';
import 'dart:io';

/// Drives the real mouse and keyboard so Gemini's tool calls turn into
/// actual clicks and keystrokes on the desktop.
///
/// There is no single cross-platform Dart API for synthetic input, so
/// this shells out to the best available tool per OS:
///   - Linux:   xdotool (apt/dnf/pacman install xdotool)
///   - macOS:   cliclick (brew install cliclick) for mouse, AppleScript
///              "System Events" for keyboard
///   - Windows: PowerShell + a small inline C# shim over user32.dll
class SystemControlService {
  /// The real-screen coordinates last passed to moveMouse/click/drag, so
  /// a screenshot can mark exactly where the cursor should now be - see
  /// AgentController, which draws this position onto every capture.
  ({int x, int y})? lastMousePosition;

  /// macOS only: proactively triggers the OS's Accessibility and
  /// Automation permission prompts up front, at session start - the
  /// same idea as ScreenCaptureService.ensurePermission() for Screen
  /// Recording. Without this, the first prompt a user ever sees is
  /// whichever tool call Gemini happens to make first, potentially deep
  /// into a session, which reads as the app randomly failing rather
  /// than a one-time setup step.
  ///
  /// There's no plugin (permission_handler included) that can check or
  /// request these directly on macOS - the only real mechanism is
  /// making the protected calls and letting the OS handle prompting
  /// (see _permissionHint's doc comment for the fuller explanation).
  /// So this just makes two deliberately harmless calls that each touch
  /// one of the two separate permission surfaces:
  ///   - listing System Events' processes needs Automation access (this
  ///     app "wants to control System Events") - what find_ui_element
  ///     and element_at_position rely on;
  ///   - an empty keystroke touches the Accessibility-trust check
  ///     (AXIsProcessTrusted) without actually typing anything - what
  ///     cliclick and real keystrokes rely on.
  /// Both failures are swallowed here: a genuinely denied permission
  /// will surface again, this time with a clear hint, the moment a real
  /// tool call needs it.
  Future<void> ensureAccessibilityPermission() async {
    if (!Platform.isMacOS) return;
    try {
      await _run('osascript', [
        '-e',
        'tell application "System Events" to get name of first process',
      ]);
    } catch (_) {
      // Ignore - see doc comment above.
    }
    try {
      await _run('osascript', [
        '-e',
        'tell application "System Events" to keystroke ""',
      ]);
    } catch (_) {
      // Ignore - see doc comment above.
    }
  }

  /// The screen size in whatever coordinate space moveMouse/click/drag
  /// actually operate in - deliberately queried through the *same* tool
  /// used for those calls (not a separate plugin like screen_retriever),
  /// so there's no risk of one reporting physical Retina pixels and the
  /// other logical points and silently scaling every click wrong.
  Future<({int width, int height})> screenSize() async {
    if (Platform.isLinux) {
      final result = await _run('xdotool', ['getdisplaygeometry']);
      final parts = result.stdout.toString().trim().split(RegExp(r'\s+'));
      return (width: int.parse(parts[0]), height: int.parse(parts[1]));
    } else if (Platform.isMacOS) {
      // "System Events" is the same automation layer keystroke/click
      // commands go through, so its notion of the desktop bounds is
      // guaranteed to match the coordinate space cliclick uses.
      final result = await _run('osascript', [
        '-e',
        'tell application "Finder" to get bounds of window of desktop',
      ]);
      final bounds = result.stdout
          .toString()
          .trim()
          .split(',')
          .map((s) => int.parse(s.trim()))
          .toList();
      final [left, top, right, bottom] = bounds;
      return (width: right - left, height: bottom - top);
    } else if (Platform.isWindows) {
      // Raw string: this PowerShell uses $b, which Dart would otherwise
      // try to interpolate as a (nonexistent) Dart variable named "b".
      final result = await _powershell(r'''
        Add-Type -AssemblyName System.Windows.Forms
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        Write-Output "$($b.Width) $($b.Height)"
      ''');
      final parts = result.stdout.toString().trim().split(RegExp(r'\s+'));
      return (width: int.parse(parts[0]), height: int.parse(parts[1]));
    }
    throw UnsupportedError('screenSize is not supported on this platform.');
  }

  /// macOS only: the name of the frontmost application's process, for
  /// use as the default `app` in findUiElement when the caller doesn't
  /// specify one.
  Future<String> frontmostProcessName() async {
    final result = await _run('osascript', [
      '-e',
      'tell application "System Events" to name of first process whose frontmost is true',
    ]);
    return result.stdout.toString().trim();
  }

  /// macOS only: asks the Accessibility API directly for the real-screen
  /// center position of a UI element whose name or description contains
  /// [searchText] (case-insensitive), searching [process]'s UI element
  /// tree. This is the OS's own exact knowledge of where a button, Dock
  /// icon, tab or menu item actually is - far more reliable than
  /// estimating a position from a screenshot, when the element can be
  /// found this way. Returns null if nothing matched (bounded search:
  /// depth 5, 400 elements visited, so a "not found" can also mean the
  /// tree was too deep/large rather than the element not existing).
  Future<({int x, int y})?> findUiElement({
    required String process,
    required String searchText,
  }) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('findUiElement is only implemented on macOS.');
    }
    final escapedProcess = _escapeAppleScriptString(process);
    final escapedSearch = _escapeAppleScriptString(searchText);

    final script = '''
      property elementCount : 0

      on searchInElement(elem, searchText, depth)
        if depth > 5 then return "NOTFOUND"
        set elementCount to elementCount + 1
        if elementCount > 400 then return "NOTFOUND"
        try
          set elemName to ""
          try
            set elemName to (name of elem) as text
          end try
          set elemDesc to ""
          try
            set elemDesc to (description of elem) as text
          end try
          set isMatch to false
          ignoring case
            if elemName contains searchText or elemDesc contains searchText then
              set isMatch to true
            end if
          end ignoring
          if isMatch then
            try
              set p to position of elem
              set s to size of elem
              set px to (item 1 of p) + ((item 1 of s) / 2)
              set py to (item 2 of p) + ((item 2 of s) / 2)
              return (px as integer as text) & "," & (py as integer as text)
            end try
          end if
        end try
        try
          set kids to UI elements of elem
          repeat with kid in kids
            set r to my searchInElement(kid, searchText, depth + 1)
            if r is not "NOTFOUND" then return r
          end repeat
        end try
        return "NOTFOUND"
      end searchInElement

      tell application "System Events"
        if not (exists process "$escapedProcess") then return "NOTFOUND"
        tell process "$escapedProcess"
          return my searchInElement(it, "$escapedSearch", 0)
        end tell
      end tell
    ''';

    final result = await _run('osascript', ['-e', script]);
    final output = result.stdout.toString().trim();
    if (output == 'NOTFOUND' || output.isEmpty) return null;

    final parts = output.split(',');
    if (parts.length != 2) return null;
    final x = int.tryParse(parts[0].trim());
    final y = int.tryParse(parts[1].trim());
    if (x == null || y == null) return null;
    return (x: x, y: y);
  }

  /// macOS only: asks the Accessibility API for the *smallest* UI
  /// element whose bounding box actually contains the real-screen point
  /// (x, y) - a reverse lookup ("what is under the cursor right now"),
  /// complementing findUiElement's forward lookup ("where is the
  /// element named X"). Picking the smallest matching element (rather
  /// than the first) avoids returning some large container that also
  /// happens to overlap the point instead of the specific control
  /// there. Same bounded search as findUiElement (depth 8 / 600
  /// elements visited). Returns null if nothing could be identified.
  Future<({String role, String name, String description})?>
      elementAtPosition({
    required String process,
    required int x,
    required int y,
  }) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('elementAtPosition is only implemented on macOS.');
    }
    final escapedProcess = _escapeAppleScriptString(process);

    final script = '''
      property elementCount : 0
      property bestArea : -1
      property bestRole : ""
      property bestName : ""
      property bestDesc : ""

      on searchInElement(elem, targetX, targetY, depth)
        if depth > 8 then return
        set elementCount to elementCount + 1
        if elementCount > 600 then return
        try
          set p to position of elem
          set s to size of elem
          set ex to item 1 of p
          set ey to item 2 of p
          set ew to item 1 of s
          set eh to item 2 of s
          if targetX >= ex and targetX <= (ex + ew) and targetY >= ey and targetY <= (ey + eh) then
            set thisArea to ew * eh
            if bestArea = -1 or thisArea < bestArea then
              set bestArea to thisArea
              set bestRole to ""
              try
                set bestRole to (role of elem) as text
              end try
              set bestName to ""
              try
                set bestName to (name of elem) as text
              end try
              set bestDesc to ""
              try
                set bestDesc to (description of elem) as text
              end try
            end if
            try
              set kids to UI elements of elem
              repeat with kid in kids
                my searchInElement(kid, targetX, targetY, depth + 1)
              end repeat
            end try
          end if
        end try
      end searchInElement

      tell application "System Events"
        if not (exists process "$escapedProcess") then return "NOTFOUND"
        tell process "$escapedProcess"
          my searchInElement(it, $x, $y, 0)
        end tell
      end tell

      if bestArea is -1 then
        return "NOTFOUND"
      else
        return bestRole & "|||" & bestName & "|||" & bestDesc
      end if
    ''';

    final result = await _run('osascript', ['-e', script]);
    final output = result.stdout.toString().trim();
    if (output == 'NOTFOUND' || output.isEmpty) return null;

    final parts = output.split('|||');
    if (parts.length != 3) return null;
    return (role: parts[0], name: parts[1], description: parts[2]);
  }

  String _escapeAppleScriptString(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  Future<void> moveMouse(int x, int y) async {
    if (Platform.isLinux) {
      await _run('xdotool', ['mousemove', '$x', '$y']);
    } else if (Platform.isMacOS) {
      await _run('cliclick', ['m:$x,$y']);
    } else if (Platform.isWindows) {
      await _powershell('[Win32]::SetCursorPos($x, $y)');
    } else {
      throw UnsupportedError('Mouse control is not supported on this platform.');
    }
    lastMousePosition = (x: x, y: y);
  }

  Future<void> click({
    int? x,
    int? y,
    String button = 'left',
    bool doubleClick = false,
  }) async {
    if (x != null && y != null) {
      await moveMouse(x, y);
    }

    if (Platform.isLinux) {
      final btn = switch (button) { 'right' => '3', 'middle' => '2', _ => '1' };
      await _run('xdotool', [
        'click',
        if (doubleClick) ...['--repeat', '2', '--delay', '120'],
        btn,
      ]);
    } else if (Platform.isMacOS) {
      final action = switch (button) {
        'right' => doubleClick ? 'drc' : 'rc',
        'middle' => 'c',
        _ => doubleClick ? 'dc' : 'c',
      };
      await _run('cliclick', ['$action:.']);
    } else if (Platform.isWindows) {
      final downFlag = switch (button) {
        'right' => '0x0008',
        'middle' => '0x0020',
        _ => '0x0002',
      };
      final upFlag = switch (button) {
        'right' => '0x0010',
        'middle' => '0x0040',
        _ => '0x0004',
      };
      final clicks = doubleClick ? 2 : 1;
      await _powershell('''
        for (\$i = 0; \$i -lt $clicks; \$i++) {
          [Win32]::mouse_event($downFlag, 0, 0, 0, 0)
          [Win32]::mouse_event($upFlag, 0, 0, 0, 0)
          Start-Sleep -Milliseconds 80
        }
      ''');
    } else {
      throw UnsupportedError('Mouse control is not supported on this platform.');
    }
  }

  Future<void> drag(int startX, int startY, int endX, int endY) async {
    if (Platform.isLinux) {
      await _run('xdotool', ['mousemove', '$startX', '$startY']);
      await _run('xdotool', ['mousedown', '1']);
      await _run('xdotool', ['mousemove', '$endX', '$endY']);
      await _run('xdotool', ['mouseup', '1']);
    } else if (Platform.isMacOS) {
      await _run('cliclick', ['dd:$startX,$startY', 'du:$endX,$endY']);
    } else if (Platform.isWindows) {
      await _powershell('''
        [Win32]::SetCursorPos($startX, $startY)
        [Win32]::mouse_event(0x0002, 0, 0, 0, 0)
        [Win32]::SetCursorPos($endX, $endY)
        [Win32]::mouse_event(0x0004, 0, 0, 0, 0)
      ''');
    } else {
      throw UnsupportedError('Mouse control is not supported on this platform.');
    }
    lastMousePosition = (x: endX, y: endY);
  }

  Future<void> typeText(String text) async {
    if (Platform.isLinux) {
      await _run('xdotool', ['type', '--clearmodifiers', text]);
    } else if (Platform.isMacOS) {
      final escaped = text.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      await _run('osascript', [
        '-e',
        'tell application "System Events" to keystroke "$escaped"',
      ]);
    } else if (Platform.isWindows) {
      final escaped = text.replaceAll('"', '""');
      await _powershell('[System.Windows.Forms.SendKeys]::SendWait("$escaped")');
    } else {
      throw UnsupportedError('Keyboard control is not supported on this platform.');
    }
  }

  Future<void> pressKey(String key) async {
    if (Platform.isLinux) {
      // xdotool's own key syntax already accepts "ctrl+alt+t" directly.
      await _run('xdotool', ['key', key]);
    } else if (Platform.isMacOS) {
      await _run('osascript', ['-e', _appleScriptKeyCommand(key)]);
    } else if (Platform.isWindows) {
      await _powershell(
        '[System.Windows.Forms.SendKeys]::SendWait("${_toSendKeysCombo(key)}")',
      );
    } else {
      throw UnsupportedError('Keyboard control is not supported on this platform.');
    }
  }

  Future<void> scroll(String direction, {int amount = 3}) async {
    if (Platform.isLinux) {
      final btn = switch (direction) {
        'up' => '4',
        'down' => '5',
        'left' => '6',
        _ => '7',
      };
      await _run('xdotool', ['click', '--repeat', '$amount', btn]);
    } else if (Platform.isMacOS) {
      final dy = direction == 'up'
          ? amount
          : direction == 'down'
              ? -amount
              : 0;
      final dx = direction == 'left'
          ? amount
          : direction == 'right'
              ? -amount
              : 0;
      await _run('cliclick', ['s:$dx,$dy']);
    } else if (Platform.isWindows) {
      final delta = (direction == 'down' || direction == 'right' ? -1 : 1) * amount * 120;
      final wheel = (direction == 'left' || direction == 'right') ? '0x1000' : '0x0800';
      await _powershell('[Win32]::mouse_event($wheel, 0, 0, $delta, 0)');
    } else {
      throw UnsupportedError('Scroll is not supported on this platform.');
    }
  }

  Future<ProcessResult> _run(String executable, List<String> args) async {
    // A hung external process (e.g. a permission dialog silently
    // waiting for a click) would otherwise block this tool call - and
    // everything after it - forever, since nothing else can proceed
    // until the awaited call resolves. Fail fast instead.
    final result = await Process.run(executable, args).timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw TimeoutException(
        'Command timed out after 8s: $executable ${args.join(' ')}',
      ),
    );
    if (result.exitCode != 0) {
      throw StateError(
        '${_permissionHint(result.stderr.toString())}'
        'Command failed: $executable ${args.join(' ')}\n${result.stderr}',
      );
    }
    return result;
  }

  /// macOS has no plugin (permission_handler included) that can check or
  /// request Accessibility/Automation access directly - the only real
  /// mechanism is to actually invoke the protected call and let the OS
  /// prompt on its own. When it's been silently denied instead (no
  /// prompt ever shown, or dismissed once), the failure is otherwise
  /// just an opaque AppleScript/cliclick error message. Recognizing the
  /// known denial text lets the error point straight at the fix instead
  /// of making the user guess which of the two separate permission
  /// panels is the problem.
  String _permissionHint(String stderr) {
    if (!Platform.isMacOS) return '';
    final lower = stderr.toLowerCase();
    if (lower.contains('not authorized') ||
        lower.contains('-1743') ||
        lower.contains('assistive access') ||
        lower.contains('accessibility api is disabled')) {
      return 'Likely a macOS permission problem, not a real command '
          'error - check System Settings -> Privacy & Security -> '
          'Accessibility AND -> Automation, and make sure "AI as a '
          'Human" is enabled in both (Automation needs its "System '
          'Events" sub-item checked too). If it isn\'t listed in either '
          'yet, that panel not registering the app at all can also mean '
          'Info.plist is missing NSAppleEventsUsageDescription - see '
          'the README.\n\n';
    }
    return '';
  }

  Future<ProcessResult> _powershell(String script) async {
    const shim = '''
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type @"
        using System.Runtime.InteropServices;
        public class Win32 {
          [DllImport("user32.dll")]
          public static extern bool SetCursorPos(int x, int y);
          [DllImport("user32.dll")]
          public static extern void mouse_event(uint flags, int dx, int dy, uint data, int extra);
        }
"@
    ''';
    return _run('powershell', ['-NoProfile', '-Command', '$shim\n$script']);
  }

  // macOS key codes for keys that AppleScript's `keystroke` can't express
  // as plain characters (used with `key code N` instead).
  static const _macKeyCodes = {
    'space': 49,
    'return': 36,
    'enter': 36,
    'escape': 53,
    'esc': 53,
    'tab': 48,
    'delete': 51,
    'backspace': 51,
    'left': 123,
    'right': 124,
    'down': 125,
    'up': 126,
  };

  /// Builds a "System Events" command for a key or combo like "cmd+space",
  /// "ctrl+c" or "Return". A previous version passed the raw string
  /// straight into `keystroke "..."`, which for a combo like "cmd+space"
  /// just typed the literal 9 characters "cmd+space" instead of actually
  /// pressing Cmd+Space - AppleScript needs modifiers expressed via a
  /// `using {command down, ...}` clause, not embedded in the key text.
  String _appleScriptKeyCommand(String key) {
    final parts = key.split('+').map((p) => p.trim().toLowerCase()).toList();
    final mainKey = parts.removeLast();

    final modifiers = parts
        .map((m) => switch (m) {
              'cmd' || 'command' => 'command down',
              'ctrl' || 'control' => 'control down',
              'alt' || 'option' => 'option down',
              'shift' => 'shift down',
              _ => null,
            })
        .whereType<String>()
        .toList();
    final using = modifiers.isEmpty ? '' : ' using {${modifiers.join(', ')}}';

    final keyCode = _macKeyCodes[mainKey];
    if (keyCode != null) {
      return 'tell application "System Events" to key code $keyCode$using';
    }

    final escaped = mainKey.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return 'tell application "System Events" to keystroke "$escaped"$using';
  }

  /// Converts a combo like "ctrl+c" or "Return" into SendKeys' own syntax
  /// (^ for Ctrl, % for Alt, + for Shift, {NAME} for named keys) - the
  /// same class of bug as the macOS one: passing "ctrl+c" straight
  /// through would type the literal text, not press Ctrl+C.
  String _toSendKeysCombo(String key) {
    const specialKeys = {
      'return': '{ENTER}',
      'enter': '{ENTER}',
      'escape': '{ESC}',
      'esc': '{ESC}',
      'tab': '{TAB}',
      'backspace': '{BACKSPACE}',
      'delete': '{DELETE}',
      'space': ' ',
      'left': '{LEFT}',
      'right': '{RIGHT}',
      'up': '{UP}',
      'down': '{DOWN}',
    };

    final parts = key.split('+').map((p) => p.trim().toLowerCase()).toList();
    final mainKey = parts.removeLast();

    final prefix = StringBuffer();
    for (final m in parts) {
      switch (m) {
        case 'ctrl':
        case 'control':
          prefix.write('^');
        case 'alt':
        case 'option':
          prefix.write('%');
        case 'shift':
          prefix.write('+');
        // SendKeys has no standard modifier symbol for the Windows key.
      }
    }

    final mapped = specialKeys[mainKey] ?? mainKey;
    // Multi-character non-special keys need SendKeys' own escaping for
    // its reserved characters; single letters/digits are safe as-is.
    return '$prefix$mapped';
  }
}
