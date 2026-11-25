# Hafen

A small KDE window with a tray icon for Docker containers. It lists the
containers grouped by Compose project and split into active and inactive.
From there you start, stop, restart and remove them. Logs and a shell open in
the terminal of your choice.

## Installation

### As a package (Ubuntu 26.04 and 26.10)

Every release ships one `.deb` per Ubuntu version. Download the matching one
from [Releases](https://github.com/bdgraue/Hafen/releases) and install it:

```sh
sudo apt install ./hafen_0.3.1_ubuntu26.10_amd64.deb
```

Hafen then appears in the application menu. To update, install the new `.deb`
the same way. Hafen reports a new version in its window at startup; you can
turn that off in the settings. To uninstall, run `sudo apt remove hafen`.

### From source

You need CMake, Qt ≥ 6.5 (Base, Declarative, Linguist tools), KF6 Kirigami,
KF6 StatusNotifierItem and KF6 DBusAddons. On Ubuntu, install them with:

```sh
sudo apt install cmake ninja-build g++ qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools \
  qt6-tools-dev qt6-l10n-tools libkirigami-dev libkf6statusnotifieritem-dev libkf6dbusaddons-dev
```

Build and install for your own user:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
cmake --build build
cmake --install build --prefix ~/.local
```

`-DBUILD_TESTING=OFF` leaves out the tests. Without that option you also need
Node.js, `dbus-run-session` and the QML module `QtTest`, see
[Development](#development).

To update, fetch the new state with `git pull` and run the same three commands
again. `cpack -G DEB` in the `build` folder creates your own `.deb`.

Runtime requirements: the Docker CLI with Compose v2. Your user has to be able
to run `docker` without `sudo`, usually through the `docker` group.

## Features

- Lists all containers from `docker ps --all` in two sections. “Active” holds
  the projects with at least one container that is running, paused or
  restarting. All others are under “Inactive”. Containers without a Compose
  label are under “Standalone containers”.
- Compose projects stay stored even after `docker compose down` has removed
  their containers. Hafen then starts them through `docker compose up`, with
  the working directory and the Compose files Docker last reported as labels.
- Hafen only offers what Docker allows in the current state. Paused containers
  are resumed instead of started. Removing is available only for created,
  exited and dead containers. Containers in a restart loop, dead containers
  and failing healthchecks are marked.
- Changes appear immediately: Hafen follows the event stream of
  `docker events`. A container you stop in a terminal is marked as stopped
  without delay. While the stream runs, Hafen otherwise reads the list again
  only every 30 seconds, in the tray every 120 seconds. If the stream breaks,
  Hafen reconnects after 5 seconds and until then reads every 5 seconds, in
  the tray every 30 seconds. When the window becomes active again, it reads
  the list at once.
- A search field filters by project and container name, including your own
  display names. Every word has to match.
- Groups show “active/total”, containers how long they have been running or
  stopped. Hovering shows a start or stop button next to it, without moving
  the layout. Stopping asks for confirmation first.
- The right-click menu offers:
  - Start, Resume, Restart and Stop… If Hafen knows the Compose files of a
    project, these actions run through `docker compose up`, `stop` and
    `restart`, that is, in the order of the dependencies.
  - Shut down…: `docker compose down` without `--volumes`. Containers and
    networks are removed, the data in volumes is kept.
  - Show logs, for a Compose project also the logs of all its containers, and
    Open shell, both in the configured terminal. The log window stays open
    after the end until you press Enter.
  - Open published ports in the browser
  - Open project folder
  - Name and color…: display name and color apply only inside Hafen.
  - Remove…: `docker rm` without `--force` and without `--volumes`. The
    confirmation starts on Cancel.
  - Forget: for stored projects without containers.
- The settings offer:
  - Terminal: Hafen finds installed terminals through their desktop entries
    (category `TerminalEmulator`, including Flatpaks) and also offers
    `x-terminal-emulator` and `xdg-terminal-exec` if present. The option that
    runs a command comes from `X-TerminalArgExec` if the terminal declares
    it. It is verified for Konsole and Kwi; for all others Hafen assumes `-e`
    and marks that as guessed. You can enter any other command.
  - CPU and memory per container and in total, from `docker stats`. The query
    runs on its own timer every 10 seconds and only while the window is
    visible. The total refers to all cores and the whole memory.
  - Docker context: it applies only to Hafen and is passed to every call as
    `--context`, including terminal commands. Stored projects are kept per
    context.
  - Notifications about crashes, restart loops, dead and unhealthy containers.
    An exit code as from `docker stop` (0, 137, 143) does not count as a crash.
  - Start in the tray at login
  - Check for new versions on GitHub
- Disk usage: shows `docker system df` and cleans up after confirmation. That
  covers stopped containers, dangling or all unused images, and the build
  cache. Hafen does not remove volumes, because they hold the data.
- Error messages name the cause: Docker is missing, the daemon is not running,
  or you have no permission on the socket. If Docker does not answer for
  20 seconds while reading the list, Hafen aborts the query and tries again
  on the next cycle.
- Tray icon: a left click shows or hides the window. If Docker is not
  reachable or a container has a problem, a warning symbol appears. The
  right-click menu lists the Compose projects with Start, Restart and Stop.
  For stopping it brings the window to the front, because of the
  confirmation. Closing only hides the window. Only one instance runs, and
  `hafen --hidden` starts without a window.

### Keyboard

| Key | Effect |
|---|---|
| ↑ ↓ | Move the highlight through groups and containers |
| → ← | Unfold and fold a group; ← jumps from a container to its group |
| Enter, Space | Unfold or fold a group, or open the container's menu |
| Menu key | Open the menu of the highlighted row |
| Delete | Remove the container, or the stopped containers of the group, with confirmation |
| L | Logs of the container or of the Compose project |
| Ctrl+F | Go to the search field; ↓ moves from there into the list, Esc clears it |
| F5 | Read the list again now |

The settings are stored in `~/.config/hafen/hafen.conf`. Hafen accesses the
network only for the update check, one request to `api.github.com` at startup,
and you can turn that off.

## Languages and translations

The texts in the source code are English. Translations are Qt Linguist files
in `i18n/hafen_<language>.ts`; German is included. Hafen loads the translation
that matches the system language and otherwise stays English.

To add a language, here French:

```sh
/usr/lib/qt6/bin/lupdate -locations none -source-language en -target-language fr \
  src -ts i18n/hafen_fr.ts
linguist i18n/hafen_fr.ts   # or translate the file with another .ts editor
cmake -S . -B build && cmake --build build
```

CMake finds every file `i18n/hafen_*.ts` by itself and compiles it in.
`cmake --build build --target update_translations` carries new or changed
texts from the code over into all language files. Translations are welcome as
pull requests.

## Development

```sh
cmake -S . -B build -G Ninja && cmake --build build
ctest --test-dir build --output-on-failure
```

`ctest` runs two test groups:

- `model` checks the logic in `src/model.mjs` under Node.js. The cases are in
  `tests/model.cases.mjs`.
- `ui` starts the real window (`src/Main.qml` and the C++ classes) and drives
  it with mouse and keyboard. The tests run without a visible window
  (`offscreen`), on their own D-Bus and against a fake `docker` in
  `tests/ui/bin/`. So they touch neither your desktop nor your containers.
  The sample data is in `tests/ui/scenario.json`. The same cases from
  `model.cases.mjs` run here once more in Qt's JavaScript engine, because it
  supports less than Node.js.

On Ubuntu you additionally need `nodejs`, `dbus-daemon` and
`qml6-module-qttest` for that. The tests store screenshots under
`build/tests/ui/artifacts/`. With `HAFEN_TEST_LANGUAGE=de` they are taken in a
translation:

```sh
HAFEN_TEST_LANGUAGE=de dbus-run-session --config-file=tests/ui/dbus-session.conf -- \
  build/tests/ui/hafen_uitest Hafen::test_screenshots
```

Release: raise the version number in `CMakeLists.txt` (`project(... VERSION)`)
and in `data/io.github.bdgraue.Hafen.metainfo.xml` (`<release>`) and describe
it in `CHANGELOG.md`. After the merge to `main`, that state gets the tag
`vX.Y.Z`. Pushing the tag builds nothing; packages and the release are started
by hand:

```sh
gh workflow run ci.yml --ref vX.Y.Z -f release=true
```

Without `-f release=true` the run only builds the `.deb` packages and attaches
them to the workflow run, from any branch or tag.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE).
