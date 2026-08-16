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
      await _run('xdotool', ['key', key]);
    } else if (Platform.isMacOS) {
      await _run('osascript', [
        '-e',
        'tell application "System Events" to keystroke "${_toAppleScriptKey(key)}"',
      ]);
    } else if (Platform.isWindows) {
      await _powershell('[System.Windows.Forms.SendKeys]::SendWait("${_toSendKeys(key)}")');
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
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) {
      throw StateError(
        'Command failed: $executable ${args.join(' ')}\n${result.stderr}',
      );
    }
    return result;
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

  String _toAppleScriptKey(String key) => key;

  String _toSendKeys(String key) {
    const specials = {
      'Return': '{ENTER}',
      'Enter': '{ENTER}',
      'Escape': '{ESC}',
      'Tab': '{TAB}',
      'Backspace': '{BACKSPACE}',
      'Delete': '{DELETE}',
    };
    return specials[key] ?? key;
  }
}
