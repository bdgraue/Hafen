# Hafen

Ein kleines KDE-Fenster mit Tray-Icon, das deine Docker-Container nach
Compose-Projekt gruppiert anzeigt. Damit lassen sich Container starten,
stoppen und neu starten. Hervorgegangen ist es aus einer Seitenleiste
für den Terminal-Workspace Herdr.

## Funktionen

- Zeigt alle Container aus `docker ps --all`. Laufende erscheinen normal,
  gestoppte abgeblendet. Container ohne Compose-Label stehen unter
  „Einzelne Container“.
- Compose-Projekte bleiben gespeichert, auch wenn `docker compose down`
  ihre Container gelöscht hat. Der Start läuft dann über
  `docker compose --project-name … --project-directory … --file … up --detach`
  mit Arbeitsverzeichnis und Compose-Dateien, die Docker zuletzt als Label
  gemeldet hat.
- Gruppen sind eingeklappt, ein Klick klappt sie auf, und der Zustand bleibt
  über Neustarts erhalten. Eingeklappte Gruppen zeigen „laufend/gesamt“ und nur
  Auffälliges: eine laufende Aktion (Spinner), eine fehlgeschlagene Aktion („!“)
  oder einen startenden bzw. fehlgeschlagenen Healthcheck (Punkt).
- Container-Zeilen zeigen den Namen ohne Projektpräfix und die Lauf- bzw.
  Stoppzeit. Image, voller Name, Status und Ports stehen im Tooltip.
- Beim Überfahren erscheint ein Start- oder Stopp-Knopf. Das Layout verschiebt
  sich dabei nicht. Gestoppt wird erst nach einer Bestätigung.
- Rechtsklick auf eine Gruppe oder einen Container öffnet ein Menü:
  - Starten, Neu starten, Stoppen…
  - Name und Farbe…: eigener Anzeigename und eigene Farbe, die nur in Hafen
    gespeichert werden. Docker selbst bleibt unverändert.
  - Name und Farbe zurücksetzen
  - Vergessen: entfernt ein gespeichertes Projekt, das keine Container mehr hat.
- Jede Aktion läuft als eigener Docker-Aufruf pro Container. Was fehlschlägt,
  meldet eine Benachrichtigung.
- Die Liste aktualisiert sich alle fünf Sekunden im Hintergrund. Abfragen
  überlappen sich nicht, und unveränderte Antworten bauen die Liste nicht neu
  auf.
- Tray-Icon: Ein Linksklick zeigt oder versteckt das Fenster, der Tooltip
  nennt die Zahl der laufenden Container. Ist Docker nicht erreichbar oder ein
  Container `unhealthy`, kommt ein Warnsymbol dazu. Schließen versteckt das
  Fenster nur, beendet wird über das Tray-Menü.
- Es läuft nur eine Instanz. Ein zweiter Start holt das vorhandene Fenster
  nach vorn. `hafen --hidden` startet nur im Tray, das ist für den Autostart
  gedacht.

Die Einstellungen liegen in `~/.config/hafen/hafen.conf`.

## Voraussetzungen

- Docker-CLI mit Compose v2. Dein Benutzer muss `docker` ohne `sudo` aufrufen
  können.
- Qt ≥ 6.5 (Quick, QuickControls2, Widgets) und CMake
- KF6 Kirigami, KF6 StatusNotifierItem und KF6 DBusAddons

## Bauen und installieren

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build
cmake --install build --prefix ~/.local
```

## Tests

```sh
node --test tests/*.test.mjs
```

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE).
