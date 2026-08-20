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
          'Force an immediate, guaranteed-fresh capture of the current '
          'screen (a clean image, then a coordinate-gridded reference '
          'image), rather than waiting for the next automatic frame '
          '(you are already shown the screen continuously on a timer). '
          'If the cursor has moved since the last frame, its position '
          'is marked with a cyan crosshair labeled "CURSOR (x,y)" on '
          'the gridded image. Use this when you specifically need to '
          'confirm something right now before your next decision.',
      'parameters': {
        'type': 'OBJECT',
        'properties': <String, dynamic>{},
      },
    },
    {
      'name': 'find_ui_element',
      'description':
          'Ask the operating system directly for the exact real-screen '
          'position of a UI element (Dock icon, button, tab, menu item) '
          'by its accessible name, instead of estimating a position '
          'from a screenshot. This is the OS\'s own precise knowledge of '
          'where the element actually is - far more reliable than '
          'visual guessing when it finds a match. Try this first for '
          'anything clickable that has a visible name or label (an app '
          'name for a Dock icon, a button\'s text, a tab\'s title, a '
          'menu item). If it returns no match, fall back to reading the '
          'screenshot\'s coordinate grid and move_mouse/take_screenshot '
          'to verify instead - not every element is reachable this way '
          '(e.g. items deep inside a complex web page).',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'name': {
            'type': 'STRING',
            'description':
                'The element\'s visible/accessible name to search for '
                '(case-insensitive substring match), e.g. "Google '
                'Chrome", "New Tab", "Settings".',
          },
          'app': {
            'type': 'STRING',
            'description':
                'Which application/process to search within. Use '
                '"Dock" for Dock icons. Omit to search the currently '
                'frontmost application.',
          },
        },
        'required': ['name'],
      },
    },
    {
      'name': 'element_at_position',
      'description':
          'Ask the operating system what UI element (if any) sits '
          'exactly at a given real-screen position - the reverse of '
          'find_ui_element. Use this right after move_mouse to verify '
          'precisely what the cursor landed on before clicking, as a '
          'more certain alternative to checking a screenshot (no visual '
          'judgment needed - either the OS confirms an element there, '
          'or it doesn\'t). Returns the element\'s role (e.g. '
          '"AXButton", "AXMenuItem", "AXDockItem"), name and '
          'description if something specific was identified there.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'x': {
            'type': 'INTEGER',
            'description': 'Real-screen X position to check.',
          },
          'y': {
            'type': 'INTEGER',
            'description': 'Real-screen Y position to check.',
          },
          'app': {
            'type': 'STRING',
            'description':
                'Which application/process to search within. Use '
                '"Dock" for Dock icons. Omit to search the currently '
                'frontmost application.',
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
          'pixel dimensions. The cursor travels to this position in '
          'several visible steps, and you are shown the cursor marker '
          'at each one, so you can see it approaching your target and '
          'immediately call move_mouse again to correct course if the '
          'final position isn\'t quite right.',
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
You are an AI operator collaborating with a human over voice. You are
continuously watching the user's screen - a fresh frame arrives every
couple of seconds on its own, like a live screen share, not just when
you ask for one - and you act on it directly with move_mouse, click,
drag, type_text, press_key and scroll.

Rules:
- Before clicking anything that has a visible name or label - a Dock
  icon, a button, a browser tab, a menu item - call find_ui_element
  with that name first. It asks the operating system directly for the
  element's exact position instead of you having to estimate one from
  a screenshot, and is far more reliable when it finds a match. Only
  fall back to reading the screenshot's coordinate grid and verifying
  with move_mouse/take_screenshot if find_ui_element returns no match.
- After a move_mouse whose landing spot you're not certain of, prefer
  calling element_at_position at that same (x, y) over inspecting a
  screenshot - it asks the OS directly what's actually there, rather
  than you having to visually judge it. If it names the element you
  expected, you're on target; if it names something else or nothing,
  correct your position before clicking.
- Each frame arrives as two images, in order: first a clean screenshot
  (exactly what the user sees, nothing drawn on it), then a second
  version with a magenta coordinate grid overlaid, each gridline
  labeled with its real-screen pixel value. Identify your target
  precisely in the clean image - the grid can visually cover small
  targets, so don't try to locate anything in the gridded one - then
  switch to the gridded image just to read off the nearest labels
  around that same spot and interpolate an exact position.
- To open/launch an application, prefer the OS app launcher over
  clicking a Dock/taskbar icon: on macOS press_key "cmd+space" (opens
  Spotlight), type_text the app name, then press_key "Return" - it's
  keyboard-only, so there's no click-target involved at all. If you do
  need to click a Dock icon directly (the user asks for it, or you're
  switching to an already-open app), use find_ui_element with app
  "Dock" first rather than guessing its position.
- Narrate briefly what you're about to do before doing it, in natural
  spoken language.
- You usually don't need to call take_screenshot manually - you're
  already being shown the screen continuously. Call it explicitly only
  when you need to force an immediate, guaranteed-fresh look right
  before a decision (e.g. right after clicking something whose result
  you must confirm before moving on), rather than waiting for the next
  automatic frame.
- Prefer small, verifiable steps over long blind sequences of actions:
  act, then look, then act again.
- Small or tightly-packed targets - Dock icons, browser tabs, toolbar
  buttons, checkboxes, and especially context/dropdown menu items - are
  easy to misjudge. Use the coordinate grid carefully for these: find
  the gridlines closest to the target on both axes and interpolate
  between their labels rather than eyeballing a position.
- For anything small or uncertain, act the way a person would: call
  move_mouse toward your target and watch it travel - you're
  automatically shown the cursor (a cyan crosshair marked "CURSOR
  (x,y)") at several points along its path, ending where it landed. If
  the final position isn't quite on the target, call move_mouse again
  to correct it and watch it travel again, repeating until the
  crosshair is confirmed on target. Only click once you've confirmed
  that. Don't skip straight to clicking on a single blind guess for
  anything small.
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
