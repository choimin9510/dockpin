# Dockpin

[한국어](README.ko.md) · [中文](README.zh-CN.md)

Dockpin is a macOS menu bar app that pins the Dock to a display and restores window layouts after sleep, display sleep, or monitor reconnection. It is a personal-use app verified on Apple Silicon and macOS 26.3.1. It requires macOS 13 or later; local builds use an ad hoc signature and are not notarized.

## Getting started

Build with Xcode Command Line Tools, then launch the app:

```sh
./scripts/build.sh
open build/Dockpin.app --args --show
```

1. Allow Dockpin in System Settings → Privacy & Security → Accessibility.
2. Enable automatic restoration to remember the current window layout.
3. To restore Dock size, grant the System Events automation permission in the app.
4. Select the display for the Dock. Use “Remember current layout” when the current arrangement is the one you want to keep.

“Restore now” applies the last saved layout. Remembering the current layout replaces the protected baseline. Replacing a local build may require granting Accessibility permission again.

## How it works

Layouts are saved per display configuration, identified by display UUID. Restoration waits for displays to settle and user input to stop, and waits up to 60 seconds for missing displays. Windows moved by the user are excluded from that restoration. After restoration starts, windows are checked for at least 30 seconds and must stay correct for 3 seconds; retries continue for up to 60 seconds. A late application resize is corrected again. Failed windows and Dock settings retain their own targets while healthy windows continue saving. Unresolved targets retry after 30 seconds of tracking when input is idle, for up to 10 seconds per retry. System Events is started in the background before checking automation permission; an idle process exit is not treated as a permission denial.

Dock movement assumes a bottom-positioned Dock and “Displays have separate Spaces.” It can fail if another display covers the target’s bottom edge or a menu is open. Dock control waits while DockLock is running. At another display’s bottom edge, Dockpin forwards mouse movements with corrected downward pressure, preserving sideways movement and upward escape instead of dropping events or warping the pointer.

The app restores normal windows that permit movement through Accessibility, including the AgentBoard main panel. Full-screen, Split View, minimized and hidden windows, moving windows between desktops, and reopening closed apps or windows are not supported. Some apps may prevent restoration through their own minimum size or Accessibility behavior.

Layouts are stored locally in `~/Library/Application Support/Dockpin/Layouts/` and may contain app identifiers, process start times, window titles and document identifiers. The directory has mode 700 and files mode 600. Dockpin does not transmit this data or record the screen. Status files are in `~/Library/Logs/`.

## Testing

```sh
./scripts/test.sh
.build/native/Dockpin --self-test
./scripts/test-integration.sh
codesign --verify --deep --strict build/Dockpin.app
```

Integration tests require Accessibility permission for the terminal and temporarily move test windows and the Dock; avoid mouse and keyboard input during the test. Quit other Dock control apps first. Full system sleep and physical cable reconnection still require real-world verification. See the [Korean documentation](README.ko.md) for detailed behavior and prior verification results.
