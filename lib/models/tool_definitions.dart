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
          'user sees before deciding on the next action. Call this '
          'whenever your mental picture of the screen might be stale.',
      'parameters': {
        'type': 'OBJECT',
        'properties': <String, dynamic>{},
      },
    },
    {
      'name': 'zoom_in',
      'description':
          'Get a magnified, cropped view centered on a rough real-screen '
          'position, to precisely pinpoint a small or tightly-packed '
          'target (a Dock icon, a browser tab, a checkbox, a toolbar '
          'button) before calling move_mouse/click/drag on it. The '
          'response image is much larger and clearer than a full '
          'screenshot; it will also state the real-screen pixel bounds '
          'the zoomed image covers so you can work out an exact position '
          'proportionally within it, the same way you already do for a '
          'full screenshot. Use this whenever a target is small or has '
          'close neighbors (e.g. several similar-looking tabs or icons) - '
          'guessing directly from the full screenshot is unreliable for '
          'these.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'x': {
            'type': 'INTEGER',
            'description':
                'Real-screen X of your rough guess at the target - the '
                'zoomed view will be centered here.',
          },
          'y': {
            'type': 'INTEGER',
            'description':
                'Real-screen Y of your rough guess at the target - the '
                'zoomed view will be centered here.',
          },
        },
        'required': ['x', 'y'],
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
- Narrate briefly what you're about to do before doing it, in natural
  spoken language.
- Take a screenshot before your first action in a task, and again any
  time the screen may have changed in a way you did not directly cause
  (page loads, animations, dialogs).
- Prefer small, verifiable steps over long blind sequences of actions:
  act, then look, then act again.
- Small or tightly-packed targets (Dock icons, browser tabs, toolbar
  buttons, checkboxes) are easy to misjudge from a full screenshot
  alone. For these, always call zoom_in on your rough guess first, use
  the magnified view to pin down an exact position, and only then call
  move_mouse/click - don't guess directly from the full screenshot for
  anything small.
- The cursor itself is not visible in screenshots, so you can't check
  your aim after moving, only after clicking. Always take_screenshot
  again right after clicking to confirm the expected change actually
  happened (a menu opened, an app launched, a checkbox toggled). If it
  didn't, re-examine the new screenshot and retry with a corrected
  position rather than assuming it worked.
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
