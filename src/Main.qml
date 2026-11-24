// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

import QtCore
import QtQml.Models
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Hafen
import "model.mjs" as Model

Kirigami.ApplicationWindow {
    id: root

    required property bool startHidden

    property var containers: []
    property bool loaded: false
    property bool loading: false
    // Only a refresh asked for by hand shows in the toolbar; the polling stays invisible.
    property bool manualLoading: false
    property bool again: false
    property string errorTitle: ""
    property string errorDetail: ""
    // Container id or "project:<name>" -> running action; container id -> message of the last failed action.
    // Reassigned, never mutated, so bindings update.
    property var busy: ({})
    property var failed: ({})
    property var openGroups: JSON.parse(settings.openGroups)
    property var closedSections: JSON.parse(settings.closedSections)
    // Compose project -> { workingDir, configFiles }, kept after `docker compose down` removed every container.
    property var remembered: JSON.parse(settings.remembered)
    // "project:<name>" or "container:<name>" -> { name, color }. Container names survive a recreate, ids do not.
    property var custom: JSON.parse(settings.custom)
    // Container id -> { cpu, mem } from `docker stats`, only while the setting is on and the window is shown.
    property var stats: ({})
    property bool statsLoading: false
    property string statsError: ""
    property var availableUpdate: null
    property bool manualUpdateCheck: false

    readonly property var groups: Model.groupContainers(containers, remembered)
    readonly property var sections: Model.splitSections(groups)
    // Group keys per section, reassigned only when groups come, go or move, and the groups by key, fresh on every refresh.
    // The list's Repeaters count keys instead of holding the data, so new data updates the rows instead of recreating them.
    property var layout: ({
            active: [],
            inactive: []
        })
    property var groupByKey: ({})
    // Stand-ins while a Repeater shrinks: a delegate about to go may evaluate once more against data that is already gone.
    readonly property var emptyGroup: ({
            project: "",
            key: "",
            members: [],
            active: []
        })
    readonly property var emptyContainer: ({
            id: "",
            name: "",
            image: "",
            status: "",
            state: "removing",
            ports: "",
            project: "",
            workingDir: "",
            configFiles: ""
        })

    onSectionsChanged: {
        const byKey = {};
        for (const g of sections.active.concat(sections.inactive))
            byKey[g.key] = g;
        groupByKey = byKey;
        const next = {
            active: sections.active.map(g => g.key),
            inactive: sections.inactive.map(g => g.key)
        };
        if (JSON.stringify(next) !== JSON.stringify(layout))
            layout = next;
    }
    readonly property int activeCount: containers.filter(Model.isActive).length
    readonly property var statsSum: Object.keys(stats).length ? Model.statsTotal(stats, Docker.cpuCount, Docker.memoryTotal) : null
    readonly property var colors: ({
            blocked: Kirigami.Theme.negativeTextColor,
            working: Kirigami.Theme.neutralTextColor,
            done: Kirigami.Theme.positiveTextColor,
            stopped: Kirigami.Theme.disabledTextColor
        })
    readonly property var swatches: ["#22a99a", "#e3814f", "#5b8def", "#8b7cf6", "#3fae6a", "#d9649a", "#d4a72c", "#e05252", "#7a8796"]

    title: "Hafen"
    width: 340
    height: 540
    minimumWidth: 260
    minimumHeight: 200
    visible: !startHidden

    onClosing: close => {
        close.accepted = false;
        root.hide();
    }

    // Coming back to the window reads at once instead of waiting for the next tick.
    onActiveChanged: {
        if (!active)
            return;
        refresh(false);
        if (settings.showStats)
            refreshStats();
    }

    Component.onCompleted: {
        if (settings.terminal === "") {
            const found = root.findTerminals().filter(t => t.verified);
            if (found.length)
                settings.terminal = found[0].command;
        }
        if (settings.checkUpdates)
            Launcher.checkForUpdate();
    }

    Settings {
        id: settings
        property string openGroups: "[]"
        property string closedSections: "[]"
        property string remembered: "{}"
        property string custom: "{}"
        property string terminal: ""
        property bool showStats: false
        property bool checkUpdates: true
        property alias windowWidth: root.width
        property alias windowHeight: root.height
    }

    Tray {
        id: tray
        window: root
        warning: root.errorTitle !== "" || root.containers.some(c => Model.condition(c) === "unhealthy")
        subtitle: root.errorTitle ? `${root.errorTitle}\n${root.errorDetail}` : root.loaded ? `${root.activeCount} aktive Container` : "Container werden geladen…"
    }

    Timer {
        interval: root.visible ? Model.REFRESH_MS : Model.HIDDEN_REFRESH_MS
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh(false)
    }

    Timer {
        interval: Model.STATS_REFRESH_MS
        running: settings.showStats && root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshStats()
        onRunningChanged: {
            if (!running) {
                root.stats = {};
                root.statsError = "";
            }
        }
    }

    Connections {
        target: Launcher
        function onUpdateChecked(tag, url) {
            let newer;
            try {
                newer = tag !== "" && Model.isNewer(tag, Launcher.version);
            } catch (e) {
                onUpdateFailed(String(e.message ?? e));
                return;
            }
            root.availableUpdate = newer ? {
                tag,
                url
            } : null;
            if (root.manualUpdateCheck && !newer)
                tray.notify("Hafen ist aktuell", `Version ${Launcher.version}`, "dialog-information");
            root.manualUpdateCheck = false;
        }
        function onUpdateFailed(message) {
            if (root.manualUpdateCheck)
                tray.notify("Suche nach Updates fehlgeschlagen", message, "dialog-error");
            root.manualUpdateCheck = false;
        }
        function onAutostartFailed(message) {
            tray.notify("Autostart ließ sich nicht ändern", message, "dialog-error");
        }
    }

    function withKey(map, key, value) {
        const next = Object.assign({}, map);
        if (value === undefined)
            delete next[key];
        else
            next[key] = value;
        return next;
    }

    function refresh(manual) {
        if (manual)
            manualLoading = true;
        if (loading) {
            if (manual)
                again = true;
            return;
        }
        loading = true;
        Docker.run(Model.DOCKER_ARGS, (code, stdout, stderr) => {
            try {
                if (code !== 0) {
                    const problem = Model.describeError(code, stderr);
                    errorTitle = problem.title;
                    errorDetail = problem.detail;
                    return;
                }
                const next = Model.parseContainers(stdout);
                // Polling unchanged data must not rebuild the list.
                if (JSON.stringify(next) !== JSON.stringify(containers))
                    containers = next;
                loaded = true;
                errorTitle = "";
                errorDetail = "";
                remember(Model.composeSources(next));
                const listed = new Set(next.map(c => c.id));
                const kept = {};
                for (const id in failed)
                    if (listed.has(id))
                        kept[id] = failed[id];
                if (Object.keys(kept).length !== Object.keys(failed).length)
                    failed = kept;
            } catch (e) {
                errorTitle = "Unerwartete Antwort von Docker";
                errorDetail = String(e.message ?? e);
            } finally {
                loading = false;
                if (again) {
                    again = false;
                    refresh(true);
                } else {
                    manualLoading = false;
                }
            }
        }, Model.READ_TIMEOUT_MS);
    }

    function refreshStats() {
        if (statsLoading)
            return;
        statsLoading = true;
        Docker.run(Model.STATS_ARGS, (code, stdout, stderr) => {
            statsLoading = false;
            // The setting may have been switched off while docker stats was running.
            if (!settings.showStats || !root.visible)
                return;
            try {
                if (code !== 0)
                    throw new Error(Model.describeError(code, stderr).title);
                stats = Model.parseStats(stdout);
                statsError = "";
            } catch (e) {
                stats = {};
                statsError = String(e.message ?? e);
            }
        }, Model.READ_TIMEOUT_MS);
    }

    function remember(sources) {
        const next = Object.assign({}, remembered, sources);
        if (JSON.stringify(next) === JSON.stringify(remembered))
            return;
        remembered = next;
        settings.remembered = JSON.stringify(next);
    }

    function forget(project) {
        remembered = withKey(remembered, project, undefined);
        settings.remembered = JSON.stringify(remembered);
        setCustom(`project:${project}`, undefined);
    }

    function setCustom(key, value) {
        custom = withKey(custom, key, value && (value.name || value.color) ? value : undefined);
        settings.custom = JSON.stringify(custom);
    }

    function projectName(project) {
        return custom[`project:${project}`]?.name || project || "Einzelne Container";
    }

    function projectColor(project) {
        const own = custom[`project:${project}`]?.color;
        if (own)
            return own;
        let hash = 0;
        for (const ch of project)
            hash = (hash * 31 + ch.codePointAt(0)) >>> 0;
        // Automatic colors use the first six swatches, the same as the spaces list in Herdr.
        return swatches[hash % 6];
    }

    function containerName(container) {
        return custom[`container:${container.name}`]?.name || Model.shortName(container);
    }

    // One docker call per container, so a partial failure names exactly which ones are affected.
    function act(action, targets, label) {
        targets = targets.filter(c => !busy[c.id]);
        if (!targets.length)
            return;
        let nowBusy = busy, nowFailed = failed;
        for (const c of targets) {
            nowBusy = withKey(nowBusy, c.id, action);
            nowFailed = withKey(nowFailed, c.id, undefined);
        }
        busy = nowBusy;
        failed = nowFailed;
        const results = [];
        for (const container of targets) {
            Docker.run(Model.actionArgs(action, container.id), (code, stdout, stderr) => {
                const result = {
                    name: container.name,
                    error: code === 0 ? null : (stderr.trim() || `Exit ${code}`)
                };
                results.push(result);
                busy = withKey(busy, container.id, undefined);
                if (result.error)
                    failed = withKey(failed, container.id, result.error);
                if (results.length < targets.length)
                    return;
                report(action, label, results);
            }, Model.NO_TIMEOUT);
        }
    }

    // `compose up` also recreates services whose containers are gone.
    function startProject(group) {
        const source = remembered[group.project];
        if (!source) {
            act("start", group.members.filter(c => Model.actionsFor(c).start), projectName(group.project));
            return;
        }
        const key = `project:${group.project}`;
        if (busy[key])
            return;
        let args;
        try {
            args = Model.composeUpArgs(group.project, source);
        } catch (e) {
            report("start", projectName(group.project), [
                {
                    name: group.project,
                    error: String(e.message ?? e)
                }
            ]);
            return;
        }
        busy = withKey(busy, key, "start");
        Docker.run(args, (code, stdout, stderr) => {
            busy = withKey(busy, key, undefined);
            report("start", projectName(group.project), [
                {
                    name: "docker compose up",
                    error: code === 0 ? null : (stderr.trim() || `Exit ${code}`)
                }
            ]);
        }, Model.NO_TIMEOUT);
    }

    function report(action, label, results) {
        const summary = Model.actionSummary(action, label, results);
        if (summary)
            tray.notify(summary.title, summary.body, summary.level === "error" ? "dialog-error" : "dialog-warning");
        refresh(true);
    }

    function launch(argv, what) {
        const problem = Launcher.detached(argv);
        if (problem)
            tray.notify(`${what} ließ sich nicht öffnen`, problem, "dialog-error");
    }

    function inTerminal(command, what) {
        let prefix;
        try {
            prefix = Model.splitCommand(settings.terminal);
        } catch (e) {
            tray.notify(`${what} ließ sich nicht öffnen`, String(e.message ?? e), "dialog-error");
            preferences.openSettings();
            return;
        }
        launch(prefix.concat(command), what);
    }

    function confirmStop(targets, label, detail) {
        stopConfirm.targets = targets;
        stopConfirm.label = label;
        stopConfirm.title = `${label} stoppen?`;
        stopConfirm.subtitle = detail;
        stopConfirm.open();
    }

    function stopGroup(group) {
        const members = group.members.filter(c => Model.actionsFor(c).stop && !busy[c.id]);
        const label = projectName(group.project);
        confirmStop(members, label, `${members.length} aktive Container des Compose-Projekts werden einzeln mit „docker stop“ angehalten: ${members.map(containerName).join(", ")}. Container, Volumes und Netzwerke bleiben erhalten.`);
    }

    function stopContainer(container) {
        confirmStop([container], containerName(container), `„${container.name}“ wird mit „docker stop“ angehalten. Der Container bleibt erhalten und lässt sich wieder starten.`);
    }

    function confirmRemove(targets, label) {
        removeConfirm.targets = targets;
        removeConfirm.label = label;
        removeConfirm.title = targets.length === 1 ? `${containerName(targets[0])} löschen?` : `${targets.length} Container von ${label} löschen?`;
        removeConfirm.subtitle = `${targets.map(c => c.name).join(", ")} ${targets.length === 1 ? "wird" : "werden"} mit „docker rm“ gelöscht. Images und Volumes bleiben erhalten; ein Compose-Projekt legt die Container beim nächsten Start neu an.`;
        removeConfirm.open();
    }

    function toggleSection(key) {
        const closed = closedSections.includes(key) ? closedSections.filter(k => k !== key) : closedSections.concat([key]);
        closedSections = closed;
        settings.closedSections = JSON.stringify(closed);
    }

    function toggleGroup(key) {
        const open = openGroups.includes(key) ? openGroups.filter(p => p !== key) : openGroups.concat([key]);
        openGroups = open;
        settings.openGroups = JSON.stringify(open);
    }

    function groupBusy(group) {
        return busy[`project:${group.project}`] !== undefined || group.members.some(c => busy[c.id] !== undefined);
    }

    function openMenu(group, container) {
        menu.group = group;
        menu.container = container;
        menu.popup();
    }

    function findTerminals() {
        return Model.terminalCandidates(Launcher.terminalEntries(), name => Launcher.hasProgram(name));
    }

    function statsText(container) {
        const s = stats[container.id];
        return s ? `${Model.formatPercent(s.cpu)} · ${Model.formatBytes(s.mem)}` : "";
    }

    Kirigami.PromptDialog {
        id: stopConfirm
        property var targets: []
        property string label: ""
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: root.act("stop", targets, label)
        Component.onCompleted: {
            const ok = standardButton(Kirigami.Dialog.Ok);
            ok.text = "Stoppen";
            ok.icon.name = "media-playback-stop";
        }
    }

    Kirigami.PromptDialog {
        id: removeConfirm
        property var targets: []
        property string label: ""
        dialogType: Kirigami.PromptDialog.Warning
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: root.act("remove", targets, label)
        // Deleting is not undone by a stray Enter: the dialog opens on Cancel.
        onOpened: standardButton(Kirigami.Dialog.Cancel).forceActiveFocus()
        Component.onCompleted: {
            const ok = standardButton(Kirigami.Dialog.Ok);
            ok.text = "Löschen";
            ok.icon.name = "edit-delete";
        }
    }

    Kirigami.Dialog {
        id: customize

        property string key: ""
        property string original: ""
        property string chosenColor: ""

        function openFor(key, original) {
            customize.key = key;
            customize.original = original;
            nameField.text = root.custom[key]?.name ?? "";
            chosenColor = root.custom[key]?.color ?? "";
            open();
            nameField.forceActiveFocus();
        }

        title: `${original} anpassen`
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 18
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: root.setCustom(key, {
            name: nameField.text.trim(),
            color: chosenColor
        })

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            QQC2.TextField {
                id: nameField
                Layout.fillWidth: true
                placeholderText: customize.original
                onAccepted: customize.accept()
            }

            Flow {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Repeater {
                    model: [""].concat(root.swatches)

                    delegate: QQC2.AbstractButton {
                        required property string modelData
                        implicitWidth: Kirigami.Units.iconSizes.medium
                        implicitHeight: implicitWidth
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.text: modelData ? modelData : "Standardfarbe"
                        onClicked: customize.chosenColor = modelData

                        background: Rectangle {
                            radius: width / 2
                            color: modelData || "transparent"
                            border.width: customize.chosenColor === modelData ? 3 : 1
                            border.color: customize.chosenColor === modelData ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                        }
                    }
                }
            }
        }
    }

    Kirigami.Dialog {
        id: preferences

        // Read again on every opening, so a terminal installed meanwhile shows up.
        property var terminals: []
        readonly property var chosen: terminals.find(t => t.command === terminalField.text.trim()) ?? null

        function openSettings() {
            terminals = root.findTerminals();
            terminalField.text = settings.terminal;
            statsBox.checked = settings.showStats;
            autostartBox.checked = Launcher.autostart;
            updatesBox.checked = settings.checkUpdates;
            open();
        }

        title: "Einstellungen"
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 24
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            settings.terminal = terminalField.text.trim();
            settings.showStats = statsBox.checked;
            settings.checkUpdates = updatesBox.checked;
            Launcher.autostart = autostartBox.checked;
        }

        Kirigami.FormLayout {
            QQC2.ComboBox {
                Kirigami.FormData.label: "Terminal:"
                visible: preferences.terminals.length > 0
                model: preferences.terminals.map(t => t.verified ? t.label : `${t.label} (Option geraten)`).concat(["Eigener Befehl"])
                currentIndex: {
                    const i = preferences.terminals.findIndex(t => t.command === terminalField.text.trim());
                    return i < 0 ? preferences.terminals.length : i;
                }
                onActivated: index => {
                    if (index < preferences.terminals.length)
                        terminalField.text = preferences.terminals[index].command;
                }
            }

            QQC2.TextField {
                id: terminalField
                Kirigami.FormData.label: preferences.terminals.length ? "Befehl:" : "Terminal:"
                Layout.fillWidth: true
                placeholderText: "z. B. konsole -e"
            }

            QQC2.Label {
                Layout.fillWidth: true
                Layout.maximumWidth: Kirigami.Units.gridUnit * 16
                wrapMode: Text.Wrap
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                text: "Hafen hängt den Befehl für Logs oder Shell an, z. B. „docker exec …“. Das Terminal muss danach einen Befehl mit Argumenten erwarten."
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.maximumWidth: Kirigami.Units.gridUnit * 16
                visible: preferences.chosen !== null && !preferences.chosen.verified
                type: Kirigami.MessageType.Warning
                text: "Dieses Terminal gibt nicht an, mit welcher Option es Befehle startet. Hafen nimmt „-e“ an. Öffnen Logs oder Shell nicht, den Befehl anpassen."
            }

            QQC2.CheckBox {
                id: statsBox
                Kirigami.FormData.label: "Anzeige:"
                text: "CPU und RAM anzeigen"
            }

            QQC2.CheckBox {
                id: autostartBox
                Kirigami.FormData.label: "Start:"
                text: "Beim Anmelden im Tray starten"
            }

            QQC2.CheckBox {
                id: updatesBox
                Kirigami.FormData.label: "Updates:"
                text: "Beim Start nach neuen Versionen suchen"
            }

            RowLayout {
                Kirigami.FormData.label: "Version:"
                QQC2.Label {
                    text: Launcher.version
                }
                QQC2.Button {
                    text: "Jetzt prüfen"
                    icon.name: "view-refresh"
                    onClicked: {
                        root.manualUpdateCheck = true;
                        Launcher.checkForUpdate();
                    }
                }
            }
        }
    }

    QQC2.Menu {
        id: menu

        property var group: null
        property var container: null
        readonly property bool forContainer: container !== null
        readonly property var actions: forContainer ? Model.actionsFor(container) : null
        readonly property bool isProject: !forContainer && (group?.project ?? "") !== ""
        readonly property var members: group?.members ?? []
        readonly property var removable: forContainer ? [] : members.filter(c => Model.actionsFor(c).remove)
        readonly property bool canStart: forContainer ? actions.start : isProject && (members.length === 0 || members.some(c => Model.actionsFor(c).start))
        readonly property bool canUnpause: forContainer ? actions.unpause : isProject && members.some(c => Model.actionsFor(c).unpause)
        readonly property bool canStop: forContainer ? actions.stop : isProject && members.some(c => Model.actionsFor(c).stop)
        readonly property bool canRestart: forContainer ? actions.restart : isProject && members.some(c => Model.actionsFor(c).restart)
        readonly property string customKey: forContainer ? `container:${container.name}` : `project:${group?.project ?? ""}`
        readonly property var ports: forContainer && Model.isRunning(container) ? Model.publishedPorts(container.ports) : []
        readonly property string label: forContainer ? root.containerName(container) : root.projectName(group?.project ?? "")

        QQC2.MenuItem {
            text: "Starten"
            icon.name: "media-playback-start"
            visible: menu.canStart
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.act("start", [menu.container], menu.label) : root.startProject(menu.group)
        }
        QQC2.MenuItem {
            text: "Fortsetzen"
            icon.name: "media-playback-start"
            visible: menu.canUnpause
            height: visible ? implicitHeight : 0
            onTriggered: root.act("unpause", menu.forContainer ? [menu.container] : menu.members.filter(c => Model.actionsFor(c).unpause), menu.label)
        }
        QQC2.MenuItem {
            text: "Neu starten"
            icon.name: "view-refresh"
            visible: menu.canRestart
            height: visible ? implicitHeight : 0
            onTriggered: root.act("restart", menu.forContainer ? [menu.container] : menu.members.filter(c => Model.actionsFor(c).restart), menu.label)
        }
        QQC2.MenuItem {
            text: "Stoppen…"
            icon.name: "media-playback-stop"
            visible: menu.canStop
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.stopContainer(menu.container) : root.stopGroup(menu.group)
        }
        QQC2.MenuSeparator {
            visible: menu.forContainer
            height: visible ? implicitHeight : 0
        }
        QQC2.MenuItem {
            text: "Logs anzeigen"
            icon.name: "view-list-text"
            visible: menu.forContainer
            height: visible ? implicitHeight : 0
            onTriggered: root.inTerminal(Model.logsCommand(menu.container), "Logs")
        }
        QQC2.MenuItem {
            text: "Shell öffnen"
            icon.name: "utilities-terminal"
            visible: menu.forContainer && menu.actions.shell
            height: visible ? implicitHeight : 0
            onTriggered: root.inTerminal(Model.shellCommand(menu.container), "Shell")
        }
        QQC2.MenuItem {
            text: "Projektordner öffnen"
            icon.name: "document-open-folder"
            visible: menu.isProject && root.remembered[menu.group.project] !== undefined
            height: visible ? implicitHeight : 0
            onTriggered: root.launch(["xdg-open", root.remembered[menu.group.project].workingDir], "Projektordner")
        }
        QQC2.MenuSeparator {
            visible: menu.forContainer || menu.isProject || menu.removable.length > 0
            height: visible ? implicitHeight : 0
        }
        QQC2.MenuItem {
            text: "Name und Farbe…"
            icon.name: "edit-rename"
            visible: menu.forContainer || menu.isProject
            height: visible ? implicitHeight : 0
            onTriggered: customize.openFor(menu.customKey, menu.forContainer ? Model.shortName(menu.container) : menu.group.project)
        }
        QQC2.MenuItem {
            text: "Name und Farbe zurücksetzen"
            icon.name: "edit-undo"
            visible: root.custom[menu.customKey] !== undefined
            height: visible ? implicitHeight : 0
            onTriggered: root.setCustom(menu.customKey, undefined)
        }
        QQC2.MenuItem {
            text: menu.forContainer ? "Löschen…" : "Gestoppte Container löschen…"
            icon.name: "edit-delete"
            visible: menu.forContainer ? menu.actions.remove : menu.removable.length > 0
            height: visible ? implicitHeight : 0
            onTriggered: root.confirmRemove(menu.forContainer ? [menu.container] : menu.removable, menu.label)
        }
        QQC2.MenuItem {
            text: "Vergessen"
            icon.name: "list-remove"
            // Docker still lists the project while any container exists; it would come straight back.
            visible: menu.isProject && menu.members.length === 0
            height: visible ? implicitHeight : 0
            onTriggered: root.forget(menu.group.project)
        }
        QQC2.MenuSeparator {
            visible: menu.ports.length > 0
            height: visible ? implicitHeight : 0
        }

        // One entry per published port, appended at the end of the menu.
        Instantiator {
            model: menu.ports
            delegate: QQC2.MenuItem {
                required property var modelData
                text: `${modelData.url.replace("http://", "")} öffnen`
                icon.name: "globe"
                onTriggered: root.launch(["xdg-open", modelData.url], "Browser")
            }
            onObjectAdded: (index, object) => menu.addItem(object)
            onObjectRemoved: (index, object) => menu.removeItem(object)
        }
    }

    pageStack.initialPage: Kirigami.ScrollablePage {
        title: root.loaded && !root.errorTitle ? `Docker · ${root.activeCount} von ${root.containers.length} aktiv` : "Docker"

        actions: [
            Kirigami.Action {
                icon.name: "view-refresh"
                text: "Aktualisieren"
                displayHint: Kirigami.DisplayHint.IconOnly
                tooltip: "Container jetzt neu einlesen"
                enabled: !root.manualLoading
                onTriggered: root.refresh(true)
            },
            Kirigami.Action {
                icon.name: "configure"
                text: "Einstellungen"
                displayHint: Kirigami.DisplayHint.IconOnly
                tooltip: "Einstellungen"
                onTriggered: preferences.openSettings()
            }
        ]

        header: ColumnLayout {
            spacing: 0

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.errorTitle !== ""
                type: Kirigami.MessageType.Error
                position: Kirigami.InlineMessage.Position.Header
                text: `${root.errorTitle}${root.loaded ? ", letzter Stand ist nicht aktuell" : ""}.\n${root.errorDetail}`
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.availableUpdate !== null
                type: Kirigami.MessageType.Information
                position: Kirigami.InlineMessage.Position.Header
                showCloseButton: true
                text: `Hafen ${root.availableUpdate?.tag ?? ""} ist verfügbar.`
                actions: [
                    Kirigami.Action {
                        text: "Herunterladen"
                        icon.name: "globe"
                        onTriggered: root.launch(["xdg-open", root.availableUpdate.url], "Download-Seite")
                    }
                ]
            }
        }

        footer: QQC2.Label {
            visible: settings.showStats && (root.statsSum !== null || root.statsError !== "")
            padding: Kirigami.Units.smallSpacing * 2
            color: root.statsError ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
            font: Kirigami.Theme.smallFont
            text: root.statsError ? `CPU/RAM: ${root.statsError}` : root.statsSum ? `Docker gesamt: CPU ${Model.formatPercent(root.statsSum.cpu)} · RAM ${Model.formatBytes(root.statsSum.mem)} (${Model.formatPercent(root.statsSum.memShare)})` : ""
        }

        ColumnLayout {
            spacing: 0
            opacity: root.errorTitle ? 0.45 : 1

            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.gridUnit * 2
                visible: !root.errorTitle && (!root.loaded || root.groups.length === 0)
                icon.name: root.loaded ? "dialog-ok" : ""
                text: root.loaded ? "Keine Container" : "Container werden geladen…"
            }

            Repeater {
                // Constant models: delegates are created once and update their bindings in place, so a refresh
                // never rebuilds the list and a hovered row keeps its hover state.
                model: ["active", "inactive"]

                delegate: ColumnLayout {
                    id: section

                    required property string modelData
                    readonly property string key: modelData
                    readonly property var keys: root.layout[key] ?? []
                    readonly property bool isOpen: !root.closedSections.includes(key)

                    Layout.fillWidth: true
                    Layout.topMargin: key === "inactive" ? Kirigami.Units.largeSpacing : 0
                    visible: keys.length > 0
                    spacing: 0

                    QQC2.ItemDelegate {
                        Layout.fillWidth: true
                        onClicked: root.toggleSection(section.key)

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing * 2

                            Kirigami.Icon {
                                source: section.isOpen ? "arrow-down" : "arrow-right"
                                implicitWidth: Kirigami.Units.iconSizes.small
                                implicitHeight: implicitWidth
                                color: Kirigami.Theme.disabledTextColor
                            }

                            QQC2.Label {
                                Layout.fillWidth: true
                                text: section.key === "active" ? "Aktiv" : "Inaktiv"
                                font.bold: true
                                color: Kirigami.Theme.disabledTextColor
                            }

                            QQC2.Label {
                                text: String(section.keys.reduce((n, k) => n + (root.groupByKey[k]?.members.length ?? 0), 0))
                                color: Kirigami.Theme.disabledTextColor
                            }
                        }
                    }

                    Kirigami.Separator {
                        Layout.fillWidth: true
                    }

                    Repeater {
                        // A count, not the groups: it only changes when groups come or go, not on every refresh.
                        model: section.isOpen ? section.keys.length : 0

                        delegate: ColumnLayout {
                            id: group

                            required property int index
                            readonly property var modelData: root.groupByKey[section.keys[index]] ?? root.emptyGroup
                            readonly property string project: modelData.project
                            readonly property string label: root.projectName(project)
                            readonly property bool isOpen: root.openGroups.includes(modelData.key)
                            readonly property bool busy: root.groupBusy(modelData)
                            readonly property bool idle: modelData.active.length === 0
                            readonly property var failedMembers: modelData.members.filter(c => root.failed[c.id])
                            readonly property string worst: Model.groupHealth(modelData.members)
                            // "Einzelne Container" only collects what has no Compose project; it is not a unit to start or stop together.
                            readonly property bool actionable: project !== "" && !busy

                            Layout.fillWidth: true
                            spacing: 0

                            QQC2.ItemDelegate {
                                Layout.fillWidth: true
                                onClicked: root.toggleGroup(group.modelData.key)

                                HoverHandler {
                                    id: headerHover
                                }
                                TapHandler {
                                    acceptedButtons: Qt.RightButton
                                    onTapped: root.openMenu(group.modelData, null)
                                }

                                contentItem: RowLayout {
                                    spacing: Kirigami.Units.smallSpacing * 2

                                    Kirigami.Icon {
                                        source: group.isOpen ? "arrow-down" : "arrow-right"
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: implicitWidth
                                        color: Kirigami.Theme.disabledTextColor
                                    }

                                    Rectangle {
                                        implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                        implicitHeight: implicitWidth
                                        radius: 5
                                        color: group.project ? root.projectColor(group.project) : "transparent"
                                        opacity: group.idle ? 0.45 : 1

                                        QQC2.Label {
                                            anchors.centerIn: parent
                                            visible: group.project !== ""
                                            text: [...group.label][0]?.toUpperCase() ?? "?"
                                            color: "#ffffff"
                                            font.bold: true
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                        Kirigami.Icon {
                                            anchors.fill: parent
                                            visible: group.project === ""
                                            source: "qrc:/qt/qml/Hafen/data/hafen.svg"
                                        }
                                    }

                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: group.label
                                        elide: Text.ElideRight
                                        color: group.idle ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.textColor
                                    }

                                    QQC2.Label {
                                        visible: group.failedMembers.length > 0
                                        text: "!"
                                        font.bold: true
                                        color: Kirigami.Theme.negativeTextColor
                                        QQC2.ToolTip.visible: failedHover.hovered
                                        QQC2.ToolTip.text: group.failedMembers.map(c => `${c.name}: ${root.failed[c.id]}`).join("\n")
                                        HoverHandler {
                                            id: failedHover
                                        }
                                    }

                                    Rectangle {
                                        visible: group.failedMembers.length === 0 && group.worst !== "ok"
                                        implicitWidth: 7
                                        implicitHeight: 7
                                        radius: 4
                                        color: group.worst === "unhealthy" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor
                                    }

                                    QQC2.Label {
                                        text: group.modelData.active.length === group.modelData.members.length || group.idle ? String(group.modelData.members.length) : `${group.modelData.active.length}/${group.modelData.members.length}`
                                        color: Kirigami.Theme.disabledTextColor
                                    }

                                    // The slot keeps its width when empty, so hovering never moves the count or the name.
                                    Item {
                                        Layout.preferredWidth: groupButton.implicitWidth
                                        Layout.preferredHeight: groupButton.implicitHeight

                                        QQC2.BusyIndicator {
                                            anchors.centerIn: parent
                                            visible: group.busy
                                            running: visible
                                            implicitWidth: Kirigami.Units.iconSizes.small
                                            implicitHeight: implicitWidth
                                            padding: 0
                                        }

                                        QQC2.ToolButton {
                                            id: groupButton
                                            anchors.centerIn: parent
                                            visible: headerHover.hovered && group.actionable
                                            icon.name: group.idle ? "media-playback-start" : "media-playback-stop"
                                            display: QQC2.AbstractButton.IconOnly
                                            text: group.idle ? `${group.label} starten` : `Alle Container von ${group.label} stoppen`
                                            QQC2.ToolTip.visible: hovered
                                            QQC2.ToolTip.text: text
                                            onClicked: group.idle ? root.startProject(group.modelData) : root.stopGroup(group.modelData)
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: group.isOpen ? group.modelData.members.length : 0

                                delegate: QQC2.ItemDelegate {
                                    id: row

                                    required property int index
                                    readonly property var modelData: group.modelData.members[index] ?? root.emptyContainer
                                    readonly property var actions: Model.actionsFor(modelData)
                                    readonly property bool busy: root.busy[modelData.id] !== undefined || root.busy[`project:${group.project}`] !== undefined
                                    readonly property string failure: root.failed[modelData.id] ?? ""
                                    readonly property string ownColor: root.custom[`container:${modelData.name}`]?.color ?? ""
                                    // The hover button offers the one obvious step for the container's state.
                                    readonly property string quickAction: actions.start ? "start" : actions.unpause ? "unpause" : actions.stop ? "stop" : ""

                                    Layout.fillWidth: true
                                    leftPadding: Kirigami.Units.gridUnit * 2
                                    QQC2.ToolTip.visible: rowHover.hovered && !rowButton.hovered
                                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                                    QQC2.ToolTip.text: failure ? `${Model.containerTooltip(modelData)}\nLetzte Aktion fehlgeschlagen: ${failure}` : Model.containerTooltip(modelData)

                                    HoverHandler {
                                        id: rowHover
                                    }
                                    TapHandler {
                                        acceptedButtons: Qt.RightButton
                                        onTapped: root.openMenu(group.modelData, row.modelData)
                                    }

                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.smallSpacing * 2

                                        Rectangle {
                                            implicitWidth: 6
                                            implicitHeight: 6
                                            radius: 3
                                            color: Model.statusColor(row.modelData, root.colors)
                                        }

                                        QQC2.Label {
                                            Layout.fillWidth: true
                                            text: root.containerName(row.modelData)
                                            elide: Text.ElideRight
                                            color: row.ownColor || (row.actions.active ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor)
                                        }

                                        QQC2.Label {
                                            visible: row.failure !== ""
                                            text: "!"
                                            font.bold: true
                                            color: Kirigami.Theme.negativeTextColor
                                        }

                                        QQC2.Label {
                                            visible: text !== ""
                                            text: settings.showStats ? root.statsText(row.modelData) : ""
                                            color: Kirigami.Theme.disabledTextColor
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }

                                        QQC2.Label {
                                            text: row.modelData.state === "paused" ? "pausiert" : Model.uptime(row.modelData.status)
                                            color: Kirigami.Theme.disabledTextColor
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }

                                        // The slot keeps its width when empty, so hovering never moves the uptime or the name.
                                        Item {
                                            Layout.preferredWidth: rowButton.implicitWidth
                                            Layout.preferredHeight: rowButton.implicitHeight

                                            QQC2.BusyIndicator {
                                                anchors.centerIn: parent
                                                visible: row.busy
                                                running: visible
                                                implicitWidth: Kirigami.Units.iconSizes.small
                                                implicitHeight: implicitWidth
                                                padding: 0
                                            }

                                            QQC2.ToolButton {
                                                id: rowButton
                                                anchors.centerIn: parent
                                                visible: !row.busy && rowHover.hovered && row.quickAction !== ""
                                                icon.name: row.quickAction === "stop" ? "media-playback-stop" : "media-playback-start"
                                                display: QQC2.AbstractButton.IconOnly
                                                text: row.quickAction === "stop" ? "Container stoppen" : row.quickAction === "unpause" ? "Container fortsetzen" : "Container starten"
                                                QQC2.ToolTip.visible: hovered
                                                QQC2.ToolTip.text: text
                                                onClicked: {
                                                    if (row.quickAction === "stop")
                                                        root.stopContainer(row.modelData);
                                                    else
                                                        root.act(row.quickAction, [row.modelData], root.containerName(row.modelData));
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
