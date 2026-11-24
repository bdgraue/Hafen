# Hafen

Ein kleines KDE-Fenster mit Tray-Icon für Docker-Container. Es zeigt die
Container gruppiert nach Compose-Projekt und getrennt nach aktiv und inaktiv.
Von dort lassen sie sich starten, stoppen, neu starten und löschen. Logs und
eine Shell öffnen sich im Terminal deiner Wahl.

## Installation

### Als Paket (Ubuntu 26.04 und 26.10)

Jedes Release enthält ein `.deb` pro Ubuntu-Version. Unter
[Releases](https://github.com/bdgraue/Hafen/releases) das passende
herunterladen und installieren:

```sh
sudo apt install ./hafen_0.3.1_ubuntu26.10_amd64.deb
```

Hafen steht danach im Anwendungsmenü. Für ein Update installierst du das neue
`.deb` auf dieselbe Weise. Hafen meldet eine neue Version beim Start im
Fenster, das lässt sich in den Einstellungen abschalten. Deinstallieren geht
mit `sudo apt remove hafen`.

### Aus dem Quellcode

Benötigt werden CMake, Qt ≥ 6.5 (Base, Declarative, Linguist-Werkzeuge),
KF6 Kirigami, KF6 StatusNotifierItem und KF6 DBusAddons. Unter Ubuntu
installierst du sie so:

```sh
sudo apt install cmake ninja-build g++ qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools \
  qt6-tools-dev qt6-l10n-tools libkirigami-dev libkf6statusnotifieritem-dev libkf6dbusaddons-dev
```

Bauen und für den eigenen Benutzer installieren:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
cmake --build build
cmake --install build --prefix ~/.local
```

`-DBUILD_TESTING=OFF` lässt die Tests weg. Ohne die Option brauchst du
zusätzlich Node.js, `dbus-run-session` und das QML-Modul `QtTest`, siehe
[Entwicklung](#entwicklung).

Für ein Update holst du mit `git pull` den neuen Stand und führst dieselben
drei Befehle noch einmal aus. Ein eigenes `.deb` erzeugt `cpack -G DEB` im
Ordner `build`.

Laufzeitvoraussetzungen: das Docker-CLI mit Compose v2. Dein Benutzer muss
`docker` ohne `sudo` aufrufen können, üblicherweise über die Gruppe `docker`.

## Funktionen

- Zeigt alle Container aus `docker ps --all`, aufgeteilt in zwei Abschnitte.
  „Aktiv“ enthält Projekte, von denen mindestens ein Container läuft, pausiert
  ist oder neu startet. Alle anderen stehen unter „Inaktiv“. Container ohne
  Compose-Label stehen unter „Einzelne Container“.
- Compose-Projekte bleiben gespeichert, auch wenn `docker compose down` ihre
  Container gelöscht hat. Gestartet werden sie dann über `docker compose up`
  mit dem Arbeitsverzeichnis und den Compose-Dateien, die Docker zuletzt als
  Label gemeldet hat.
- Angeboten wird nur, was Docker im jeweiligen Zustand zulässt. Pausierte
  Container werden fortgesetzt statt gestartet. Löschen gibt es nur für
  erstellte, beendete und tote Container. Container in einer Neustart-Schleife,
  tote Container und fehlgeschlagene Healthchecks sind markiert.
- Änderungen erscheinen sofort: Hafen liest den Ereignisstrom von
  `docker events` mit. Ein Container, den du im Terminal stoppst, ist ohne
  Verzögerung als gestoppt markiert. Solange der Strom läuft, liest Hafen
  sonst nur alle 30 Sekunden neu ein, im Tray alle 120 Sekunden. Bricht der
  Strom ab, verbindet Hafen nach 5 Sekunden neu und liest bis dahin alle 5
  bzw. 30 Sekunden ein. Wird das Fenster wieder aktiv, liest es sofort neu ein.
- Ein Suchfeld filtert nach Projekt- und Containernamen, auch nach eigenen
  Anzeigenamen. Jedes Wort muss vorkommen.
- Gruppen zeigen „aktiv/gesamt“, Container ihre Lauf- bzw. Stoppzeit. Beim
  Überfahren erscheint daneben ein Start- oder Stopp-Knopf, ohne dass sich das
  Layout verschiebt. Gestoppt wird erst nach einer Bestätigung.
- Das Rechtsklick-Menü bietet:
  - Starten, Fortsetzen, Neu starten und Stoppen… Kennt Hafen die
    Compose-Dateien eines Projekts, laufen diese Aktionen über
    `docker compose up`, `stop` und `restart`, also in der Reihenfolge der
    Abhängigkeiten.
  - Herunterfahren…: `docker compose down` ohne `--volumes`. Container und
    Netzwerke werden entfernt, die Daten in Volumes bleiben.
  - Logs anzeigen, für ein Compose-Projekt auch die Logs aller Container, und
    Shell öffnen, jeweils im eingestellten Terminal. Das Logfenster bleibt
    nach dem Ende offen, bis du Enter drückst.
  - Veröffentlichte Ports im Browser öffnen
  - Projektordner öffnen
  - Name und Farbe…: Anzeigename und Farbe gelten nur in Hafen.
  - Löschen…: `docker rm` ohne `--force` und ohne `--volumes`. Die Bestätigung
    steht vorab auf Abbrechen.
  - Vergessen: für gespeicherte Projekte ohne Container.
- In den Einstellungen gibt es:
  - Terminal: Hafen findet installierte Terminals über ihre Desktop-Einträge
    (Kategorie `TerminalEmulator`, auch Flatpaks) und bietet außerdem
    `x-terminal-emulator` und `xdg-terminal-exec` an, wenn vorhanden. Die
    Option zum Ausführen eines Befehls stammt aus `X-TerminalArgExec`, falls
    das Terminal sie angibt. Für Konsole und Kwi ist sie geprüft, für alle
    anderen nimmt Hafen „-e“ an und markiert das als geraten. Jeder andere
    Befehl lässt sich eintragen.
  - CPU und RAM pro Container und gesamt, aus `docker stats`. Die Abfrage
    läuft auf einem eigenen Timer alle 10 Sekunden und nur bei sichtbarem
    Fenster. Der Gesamtwert ist auf alle Kerne und den ganzen Arbeitsspeicher
    bezogen.
  - Docker-Kontext: Er gilt nur für Hafen und wird jedem Aufruf als
    `--context` mitgegeben, auch Terminal-Befehlen. Gemerkte Projekte liegen je
    Kontext.
  - Meldungen bei Abstürzen, Neustart-Schleifen, toten und kranken Containern.
    Ein Exit-Code wie bei `docker stop` (0, 137, 143) gilt nicht als Absturz.
  - Autostart im Tray beim Anmelden
  - Suche nach neuen Versionen bei GitHub
- Speicherplatz: zeigt `docker system df` und räumt mit Bestätigung auf. Das
  betrifft gestoppte Container, verwaiste oder alle ungenutzten Images und den
  Build-Cache. Volumes löscht Hafen nicht, weil darin die Daten liegen.
- Fehlermeldungen nennen die Ursache: Docker fehlt, der Dienst läuft nicht
  oder du hast keine Rechte am Socket. Antwortet Docker beim Einlesen
  20 Sekunden lang nicht, bricht Hafen die Abfrage ab und versucht es beim
  nächsten Takt erneut.
- Tray-Icon: Ein Linksklick zeigt oder versteckt das Fenster. Ist Docker nicht
  erreichbar oder ein Container auffällig, erscheint ein Warnsymbol. Das
  Rechtsklick-Menü listet die Compose-Projekte mit Starten, Neu starten und
  Stoppen. Fürs Stoppen holt es das Fenster wegen der Bestätigung nach vorn.
  Schließen versteckt das Fenster nur. Es läuft nur eine Instanz, und
  `hafen --hidden` startet ohne Fenster.

### Tastatur

| Taste | Wirkung |
|---|---|
| ↑ ↓ | Markierung durch Gruppen und Container bewegen |
| → ← | Gruppe auf- und zuklappen; ← springt vom Container zu seiner Gruppe |
| Enter, Leertaste | Gruppe auf- und zuklappen bzw. Menü des Containers öffnen |
| Menü-Taste | Menü der markierten Zeile öffnen |
| Entf | Container löschen bzw. die gestoppten Container der Gruppe, mit Bestätigung |
| L | Logs des Containers bzw. des Compose-Projekts |
| Strg+F | ins Suchfeld; ↓ wechselt von dort in die Liste, Esc leert es |
| F5 | sofort neu einlesen |

Die Einstellungen liegen in `~/.config/hafen/hafen.conf`. Netzwerkzugriff gibt
es nur für die Update-Suche, eine Anfrage an `api.github.com` beim Start, und
die lässt sich abschalten.

## Sprachen und Übersetzungen

Die Texte im Quellcode sind englisch. Übersetzungen liegen als
Qt-Linguist-Dateien in `i18n/hafen_<sprache>.ts`, mitgeliefert ist Deutsch.
Hafen lädt die Übersetzung, die zur Systemsprache passt, und bleibt sonst
englisch.

Eine neue Sprache, hier Französisch, kommt so dazu:

```sh
/usr/lib/qt6/bin/lupdate -locations none -source-language en -target-language fr \
  src -ts i18n/hafen_fr.ts
linguist i18n/hafen_fr.ts   # oder die Datei mit einem anderen .ts-Editor übersetzen
cmake -S . -B build && cmake --build build
```

CMake findet jede Datei `i18n/hafen_*.ts` von selbst und kompiliert sie ein.
Neue oder geänderte Texte im Code überträgt
`cmake --build build --target update_translations` in alle Sprachdateien.
Übersetzungen nehme ich gern als Pull Request an.

## Entwicklung

```sh
cmake -S . -B build -G Ninja && cmake --build build
ctest --test-dir build --output-on-failure
```

`ctest` führt zwei Testgruppen aus:

- `model` prüft die Logik in `src/model.mjs` unter Node.js. Die Fälle stehen
  in `tests/model.cases.mjs`.
- `ui` startet das echte Fenster (`src/Main.qml` und die C++-Klassen) und
  bedient es mit Maus und Tastatur. Die Tests laufen ohne sichtbares Fenster
  (`offscreen`), auf einem eigenen D-Bus und gegen ein nachgebautes `docker`
  in `tests/ui/bin/`. Sie berühren also weder deinen Desktop noch deine
  Container. Die Beispieldaten stehen in `tests/ui/scenario.json`. Dieselben
  Fälle aus `model.cases.mjs` laufen hier noch einmal in Qts JavaScript-Engine,
  weil die weniger versteht als Node.js.

Unter Ubuntu brauchst du dafür zusätzlich `nodejs`, `dbus-daemon` und
`qml6-module-qttest`. Die Tests legen Screenshots unter
`build/tests/ui/artifacts/` ab. Mit `HAFEN_TEST_LANGUAGE=de` entstehen sie in
einer Übersetzung:

```sh
HAFEN_TEST_LANGUAGE=de dbus-run-session --config-file=tests/ui/dbus-session.conf -- \
  build/tests/ui/hafen_uitest Hafen::test_screenshots
```

Release: Die Versionsnummer wird in `CMakeLists.txt` (`project(... VERSION)`)
und in `data/io.github.bdgraue.Hafen.metainfo.xml` (`<release>`) angehoben und
in `CHANGELOG.md` beschrieben. Nach dem Merge auf `main` erhält dieser Stand
das Tag `vX.Y.Z`. Die CI baut daraus die `.deb`-Pakete und legt das Release an.

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE).
