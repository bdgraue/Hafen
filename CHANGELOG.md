# Changelog

## 0.3.1

Bug fixes, found with the new UI tests:

- Compose projects could not be started, stopped, restarted or shut down, and
  their logs did not open: Qt's JavaScript engine does not know
  `Array.prototype.flatMap`. This affected 0.2.0 and 0.3.0.
- The disk usage dialog stayed empty.
- Long texts ran past the edge of the settings dialog; it now has a single
  column.
- A right click on “Standalone containers” opened an empty menu.
- Ctrl+F was bound twice and therefore did nothing.
- The blue highlight of the keyboard navigation stayed after a mouse click.
  It now appears only after a key press.
- The list of terminals appeared in random order, because Qt's `sort` is not
  stable.
- The tooltip of a row covered the context menu.
- Warnings in the log when opening the menu and the settings.

New: UI tests (`ctest`) that drive the window offscreen against a fake
`docker`; the logic tests additionally run in Qt's JavaScript engine.

## 0.3.0

- Changes appear immediately through `docker events`; the periodic read runs
  only every 30 s (tray: 120 s) as a fallback.
- Compose projects start, stop and restart through `docker compose`, in the
  order of their dependencies; new is Shut down (`docker compose down` without
  `--volumes`).
- Logs of all containers of a Compose project in the terminal.
- Search field for projects and containers.
- Tray menu with the Compose projects.
- Notifications about crashes, restart loops, dead and unhealthy containers.
- Show and clean up disk usage (containers, images, build cache).
- Selectable Docker context; stored projects per context.
- Translatable: English as the source, German included, further languages as
  `i18n/hafen_<language>.ts`.
- Keyboard navigation.
- The window title names only the daemon; the counts are in the section
  headers and the tray tooltip.
- Fixed: projects appeared unsorted in the app, because Qt's JavaScript engine
  sorts wrongly with destructured comparison functions.

## 0.2.0

- List split into “Active” and “Inactive”, both collapsible.
- Docker states are told apart exactly: paused containers are resumed instead
  of started, containers in a restart loop and dead containers are marked.
- Right-click menu: logs and a shell in the configured terminal, published
  ports in the browser, open the project folder, remove stopped containers
  (`docker rm` without `--force` and `--volumes`, the confirmation starts on
  Cancel).
- Settings: terminal command (Hafen finds installed terminals through their
  desktop entries including Flatpaks, plus `x-terminal-emulator` and
  `xdg-terminal-exec`), CPU and memory per container and in total (own timer,
  only while the window is visible), autostart, check for new versions.
- Hidden in the tray, Hafen polls only every 30 seconds. When the window
  becomes active again, it reads the list at once.
- Error messages name the cause: Docker is missing, the daemon is not running,
  or no permission on the socket. A hanging Docker daemon no longer blocks the
  list; reading aborts after 20 seconds.
- Count and uptime stay visible while hovering. New data updates the existing
  rows instead of rebuilding the list; a hover button no longer disappears on
  every refresh.
- Packaging as `.deb` with the app ID `io.github.bdgraue.Hafen`, AppStream
  metadata and `hafen --version`.

## 0.1.0

- First version.
