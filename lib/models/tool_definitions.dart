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
      'name': 'move_mouse',
      'description':
          'Move the mouse cursor to an absolute position on screen. '
          'Coordinates are normalized to a 0-1000 scale relative to the '
          'most recent screenshot you were shown (0,0 = its top-left '
          'corner, 1000,1000 = its bottom-right corner) - the same '
          'convention you already use for bounding boxes/spatial '
          'reasoning about images. They are automatically converted to '
          'real screen coordinates.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'x': {
            'type': 'INTEGER',
            'description':
                'Horizontal position, 0-1000 normalized to the last '
                'screenshot width. 0 = left edge, 1000 = right edge.',
          },
          'y': {
            'type': 'INTEGER',
            'description':
                'Vertical position, 0-1000 normalized to the last '
                'screenshot height. 0 = top edge, 1000 = bottom edge.',
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
                'Optional X to move to first, 0-1000 normalized to the '
                'last screenshot width.',
          },
          'y': {
            'type': 'INTEGER',
            'description':
                'Optional Y to move to first, 0-1000 normalized to the '
                'last screenshot height.',
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
          'coordinates are 0-1000 normalized to the last screenshot, '
          'same as move_mouse.',
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
- Never perform destructive actions (deleting files, submitting
  payments, sending messages, changing security settings) without
  confirming with the user first, out loud.
- If the screen doesn't match what you expected, stop and ask the user
  rather than guessing.
''';
}
