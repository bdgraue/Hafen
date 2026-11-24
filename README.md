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
sudo apt install ./hafen_0.2.0_ubuntu26.10_amd64.deb
```

Hafen steht danach im Anwendungsmenü. Für ein Update installierst du das neue
`.deb` auf dieselbe Weise. Hafen meldet eine neue Version beim Start im
Fenster, das lässt sich in den Einstellungen abschalten. Deinstallieren geht
mit `sudo apt remove hafen`.

### Aus dem Quellcode

Benötigt werden CMake, Qt ≥ 6.5 (Base, Declarative), KF6 Kirigami,
KF6 StatusNotifierItem und KF6 DBusAddons. Unter Ubuntu installierst du sie so:

```sh
sudo apt install cmake ninja-build g++ qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools \
  libkirigami-dev libkf6statusnotifieritem-dev libkf6dbusaddons-dev
```

Bauen und für den eigenen Benutzer installieren:

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
cmake --install build --prefix ~/.local
```

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
- Gruppen zeigen „aktiv/gesamt“, Container ihre Lauf- bzw. Stoppzeit. Beim
  Überfahren erscheint daneben ein Start- oder Stopp-Knopf, ohne dass sich das
  Layout verschiebt. Gestoppt wird erst nach einer Bestätigung.
- Das Rechtsklick-Menü bietet:
  - Starten, Fortsetzen, Neu starten und Stoppen…
  - Logs anzeigen und Shell öffnen im eingestellten Terminal. Das Logfenster
    bleibt nach dem Ende offen, bis du Enter drückst.
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
  - Autostart im Tray beim Anmelden
  - Suche nach neuen Versionen bei GitHub
- Bei sichtbarem Fenster liest Hafen alle 5 Sekunden neu ein, im Tray alle
  30 Sekunden. Wird das Fenster wieder aktiv, liest es sofort neu ein.
- Fehlermeldungen nennen die Ursache: Docker fehlt, der Dienst läuft nicht
  oder du hast keine Rechte am Socket. Antwortet Docker beim Einlesen
  20 Sekunden lang nicht, bricht Hafen die Abfrage ab und versucht es beim
  nächsten Takt erneut.
- Tray-Icon: Ein Linksklick zeigt oder versteckt das Fenster. Ist Docker nicht
  erreichbar oder ein Container auffällig, erscheint ein Warnsymbol.
  Schließen versteckt das Fenster nur. Es läuft nur eine Instanz, und
  `hafen --hidden` startet ohne Fenster.

Die Einstellungen liegen in `~/.config/hafen/hafen.conf`. Netzwerkzugriff gibt
es nur für die Update-Suche, eine Anfrage an `api.github.com` beim Start, und
die lässt sich abschalten.

## Entwicklung

```sh
node --test tests/*.test.mjs
```

Release: Die Versionsnummer wird in `CMakeLists.txt` (`project(... VERSION)`)
und in `data/io.github.bdgraue.Hafen.metainfo.xml` (`<release>`) angehoben und
in `CHANGELOG.md` beschrieben. Nach dem Merge auf `main` erhält dieser Stand
das Tag `vX.Y.Z`. Die CI baut daraus die `.deb`-Pakete und legt das Release an.

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE).
