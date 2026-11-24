# Changelog

## 0.3.0

- Änderungen erscheinen sofort über `docker events`; das regelmäßige Einlesen
  läuft nur noch alle 30 s (Tray: 120 s) als Rückfall.
- Compose-Projekte starten, stoppen und starten neu über `docker compose`, in
  der Reihenfolge ihrer Abhängigkeiten; neu ist Herunterfahren
  (`docker compose down` ohne `--volumes`).
- Logs aller Container eines Compose-Projekts im Terminal.
- Suchfeld für Projekte und Container.
- Tray-Menü mit den Compose-Projekten.
- Meldungen bei Abstürzen, Neustart-Schleifen, toten und kranken Containern.
- Speicherplatz anzeigen und aufräumen (Container, Images, Build-Cache).
- Docker-Kontext wählbar; gemerkte Projekte je Kontext.
- Übersetzbar: Englisch als Quelle, Deutsch mitgeliefert, weitere Sprachen als
  `i18n/hafen_<sprache>.ts`.
- Tastatursteuerung.
- Die Fensterüberschrift nennt nur noch den Daemon; die Zahlen stehen in den
  Abschnittsköpfen und im Tray-Tooltip.
- Behoben: Projekte erschienen in der App unsortiert, weil Qts
  JavaScript-Engine destrukturierte Vergleichsfunktionen falsch sortiert.

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
