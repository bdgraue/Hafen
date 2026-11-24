# Changelog

## 0.2.0

- Liste getrennt nach „Aktiv“ und „Inaktiv“, beide einklappbar.
- Docker-Zustände werden genau unterschieden: Pausierte Container lassen sich
  fortsetzen statt starten, Container in einer Neustart-Schleife und tote
  Container sind als auffällig markiert.
- Rechtsklick-Menü: Logs und Shell im eingestellten Terminal, veröffentlichte
  Ports im Browser, Projektordner öffnen, gestoppte Container löschen
  (`docker rm` ohne `--force` und `--volumes`, Bestätigung steht auf Abbrechen).
- Einstellungen: Terminal-Befehl. Hafen findet installierte Terminals über
  ihre Desktop-Einträge samt Flatpaks, dazu `x-terminal-emulator` und
  `xdg-terminal-exec`,
  CPU und RAM pro Container und gesamt (eigener Timer, nur bei sichtbarem
  Fenster), Autostart, Suche nach neuen Versionen.
- Versteckt im Tray fragt Hafen nur noch alle 30 Sekunden ab. Wird das Fenster
  wieder aktiv, liest es sofort neu ein.
- Fehlermeldungen nennen die Ursache: Docker fehlt, Dienst läuft nicht oder
  keine Rechte am Socket. Ein hängender Docker-Dienst blockiert die Liste nicht
  mehr, das Einlesen bricht nach 20 Sekunden ab.
- Anzahl und Laufzeit bleiben beim Überfahren sichtbar. Neue Daten
  aktualisieren die vorhandenen Zeilen, statt die Liste neu aufzubauen; ein
  Hover-Knopf verschwindet nicht mehr bei jeder Aktualisierung.
- Paketierung als `.deb` mit App-ID `io.github.bdgraue.Hafen`,
  AppStream-Metadaten und `hafen --version`.

## 0.1.0

- Erste Version.
