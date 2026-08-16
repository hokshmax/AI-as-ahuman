/// Function ("tool") declarations exposed to Gemini during the Live
/// session. These are what let the model act on the screen instead of
/// just describing what it would do.
library;

class ToolDefinitions {
  ToolDefinitions._();

  static const List<Map<String, dynamic>> declarations = [
    {
      'name': 'take_screenshot',
      'description':
          'Capture the current screen so you can see exactly what the '
          'user sees before deciding on the next action. If the cursor '
          'has moved since the last screenshot, its current position is '
          'marked with a cyan crosshair labeled "CURSOR (x,y)" - use '
          'this to verify move_mouse actually landed where you intended '
          'before clicking. Call this whenever your mental picture of '
          'the screen might be stale, and always after a move_mouse '
          'whose accuracy you need to confirm.',
      'parameters': {
        'type': 'OBJECT',
        'properties': <String, dynamic>{},
      },
    },
    {
      'name': 'move_mouse',
      'description':
          'Move the mouse cursor to an absolute position on screen. '
          'Coordinates are real screen pixel coordinates - see the '
          'screen resolution stated in your system instructions - not '
          'normalized and not relative to the screenshot image size. '
          'Work out the position proportionally: if something appears '
          'at roughly the horizontal/vertical midpoint of the '
          'screenshot, its x/y are roughly the screen width/height '
          'midpoints too, regardless of the screenshot image\'s own '
          'pixel dimensions.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'x': {
            'type': 'INTEGER',
            'description':
                'Horizontal pixel coordinate on the real screen, 0 = '
                'left edge.',
          },
          'y': {
            'type': 'INTEGER',
            'description':
                'Vertical pixel coordinate on the real screen, 0 = top '
                'edge.',
          },
        },
        'required': ['x', 'y'],
      },
    },
    {
      'name': 'click',
      'description':
          'Click at the current cursor position, or move-then-click if '
          'x/y are given.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'x': {
            'type': 'INTEGER',
            'description':
                'Optional X to move to first, real screen pixel coordinate.',
          },
          'y': {
            'type': 'INTEGER',
            'description':
                'Optional Y to move to first, real screen pixel coordinate.',
          },
          'button': {
            'type': 'STRING',
            'enum': ['left', 'right', 'middle'],
            'description': 'Mouse button to click. Defaults to left.',
          },
          'double_click': {
            'type': 'BOOLEAN',
            'description': 'Whether to double-click instead of single-click.',
          },
        },
        'required': <String>[],
      },
    },
    {
      'name': 'drag',
      'description': 'Press the mouse button at one point and release it '
          'at another, e.g. to drag a slider or select text. All '
          'coordinates are real screen pixel coordinates, same as '
          'move_mouse.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'start_x': {'type': 'INTEGER'},
          'start_y': {'type': 'INTEGER'},
          'end_x': {'type': 'INTEGER'},
          'end_y': {'type': 'INTEGER'},
        },
        'required': ['start_x', 'start_y', 'end_x', 'end_y'],
      },
    },
    {
      'name': 'type_text',
      'description': 'Type text at the current cursor/focus position, as '
          'if typed on a keyboard.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'text': {'type': 'STRING'},
        },
        'required': ['text'],
      },
    },
    {
      'name': 'press_key',
      'description':
          'Press a single key or key combination, e.g. "Return", '
          '"Escape", "ctrl+c", "alt+Tab".',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'key': {'type': 'STRING'},
        },
        'required': ['key'],
      },
    },
    {
      'name': 'scroll',
      'description': 'Scroll the screen at the current cursor position.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'direction': {
            'type': 'STRING',
            'enum': ['up', 'down', 'left', 'right'],
          },
          'amount': {
            'type': 'INTEGER',
            'description': 'Number of scroll notches. Defaults to 3.',
          },
        },
        'required': ['direction'],
      },
    },
  ];

  static const String systemInstruction = '''
You are an AI operator collaborating with a human over voice. You can see
the user's screen through the take_screenshot tool and act on it directly
with move_mouse, click, drag, type_text, press_key and scroll.

Rules:
- Every screenshot has a magenta coordinate grid drawn over it, with
  each gridline labeled with its real-screen pixel value. This is a
  reference overlay, not part of the actual UI - use it to read off the
  nearest labels around your target and interpolate an exact position,
  rather than estimating a raw pixel coordinate with nothing to anchor
  against.
- To open/launch an application, prefer the OS app launcher over
  clicking a Dock/taskbar icon: on macOS press_key "cmd+space" (opens
  Spotlight), type_text the app name, then press_key "Return". Dock
  icons are small, visually similar to each other, and easy to
  misidentify entirely (not just imprecisely click) - Spotlight sidesteps
  that completely since it's keyboard-only. Only click a Dock/taskbar
  icon directly if the user specifically asks to, or the app is already
  open and you're switching to it.
- Narrate briefly what you're about to do before doing it, in natural
  spoken language.
- Take a screenshot before your first action in a task, and again any
  time the screen may have changed in a way you did not directly cause
  (page loads, animations, dialogs).
- Prefer small, verifiable steps over long blind sequences of actions:
  act, then look, then act again.
- Small or tightly-packed targets - Dock icons, browser tabs, toolbar
  buttons, checkboxes, and especially context/dropdown menu items - are
  easy to misjudge. Use the coordinate grid carefully for these: find
  the gridlines closest to the target on both axes and interpolate
  between their labels rather than eyeballing a position.
- For anything small or uncertain, act the way a person would: move
  the cursor toward your target first with move_mouse, then
  take_screenshot to actually look at where it landed - a cyan
  crosshair marked "CURSOR (x,y)" shows you exactly where it is. If
  it's not on the target yet, move_mouse again to correct it and check
  again. Only click once the crosshair is confirmed on target. Don't
  skip straight to clicking on a single blind guess for anything
  small - verify the cursor position first.
- After clicking, take_screenshot again to confirm the expected change
  actually happened (a menu opened, an app launched, a checkbox
  toggled). If it didn't, or the WRONG thing happened (e.g. a different
  app opened than intended), don't just retry blindly - undo it first
  (close/quit the wrong app or menu) so you're not stacking mistakes,
  then retry with a corrected position or approach.
- Never perform destructive actions (deleting files, submitting
  payments, sending messages, changing security settings) without
  confirming with the user first, out loud.
- If the screen doesn't match what you expected, stop and ask the user
  rather than guessing.
''';

  /// Appended to the system instruction once the real screen size is
  /// known (see AgentController.start(), which fetches it before
  /// connecting). Telling Gemini the exact target resolution and asking
  /// for direct pixel coordinates in that space removes any ambiguity
  /// about which normalization convention it should use.
  static String screenResolutionInstruction(int width, int height) => '''
The screen you are controlling is exactly ${width}x$height pixels.
Every screenshot you're shown, regardless of its own image dimensions,
represents this same ${width}x$height screen. When calling move_mouse,
click or drag, always give x/y as direct pixel coordinates on this
${width}x$height screen - work out the position proportionally from
where you see the target in the screenshot (e.g. a target at the
screenshot's horizontal midpoint has x roughly ${width ~/ 2}).
''';
}
