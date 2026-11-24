// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

import QtCore
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
    // Only a refresh asked for by hand shows in the toolbar; the five-second polling stays invisible.
    property bool manualLoading: false
    property bool again: false
    property string error: ""
    // Container id or "project:<name>" -> running action; container id -> message of the last failed action.
    // Reassigned, never mutated, so bindings update.
    property var busy: ({})
    property var failed: ({})
    property var openGroups: JSON.parse(settings.openGroups)
    // Compose project -> { workingDir, configFiles }, kept after `docker compose down` removed every container.
    property var remembered: JSON.parse(settings.remembered)
    // "project:<name>" or "container:<name>" -> { name, color }. Container names survive a recreate, ids do not.
    property var custom: JSON.parse(settings.custom)

    readonly property var groups: Model.groupContainers(containers, remembered)
    readonly property int runningCount: containers.filter(Model.isRunning).length
    readonly property var colors: ({
            blocked: Kirigami.Theme.negativeTextColor,
            working: Kirigami.Theme.neutralTextColor,
            done: Kirigami.Theme.positiveTextColor,
            stopped: Kirigami.Theme.disabledTextColor
        })
    readonly property var swatches: ["#22a99a", "#e3814f", "#5b8def", "#8b7cf6", "#3fae6a", "#d9649a", "#d4a72c", "#e05252", "#7a8796"]

    title: "Hafen"
    width: 320
    height: 520
    minimumWidth: 240
    minimumHeight: 200
    visible: !startHidden

    onClosing: close => {
        close.accepted = false;
        root.hide();
    }

    Settings {
        id: settings
        property string openGroups: "[]"
        property string remembered: "{}"
        property string custom: "{}"
        property alias windowWidth: root.width
        property alias windowHeight: root.height
    }

    Tray {
        id: tray
        window: root
        warning: root.error !== "" || root.containers.some(c => Model.isRunning(c) && Model.health(c.status) === "unhealthy")
        subtitle: root.error ? `Docker nicht erreichbar\n${root.error}` : root.loaded ? `${root.runningCount} laufende Container` : "Container werden geladen…"
    }

    Timer {
        interval: Model.REFRESH_MS
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh(false)
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
                if (code !== 0)
                    throw new Error(stderr.trim() || `Docker: Exit ${code}`);
                const next = Model.parseContainers(stdout);
                // Polling unchanged data must not rebuild the list.
                if (JSON.stringify(next) !== JSON.stringify(containers))
                    containers = next;
                loaded = true;
                error = "";
                remember(Model.composeSources(next));
                const listed = new Set(next.map(c => c.id));
                const kept = {};
                for (const id in failed)
                    if (listed.has(id))
                        kept[id] = failed[id];
                if (Object.keys(kept).length !== Object.keys(failed).length)
                    failed = kept;
            } catch (e) {
                error = String(e.message ?? e);
            } finally {
                loading = false;
                if (again) {
                    again = false;
                    refresh(true);
                } else {
                    manualLoading = false;
                }
            }
        });
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
            Docker.run([action, container.id], (code, stdout, stderr) => {
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
            });
        }
    }

    // `compose up` also recreates services whose containers are gone.
    function startProject(group) {
        const source = remembered[group.project];
        if (!source) {
            act("start", group.members.filter(c => !Model.isRunning(c)), projectName(group.project));
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
        });
    }

    function report(action, label, results) {
        const summary = Model.actionSummary(action, label, results);
        if (summary)
            tray.notify(summary.title, summary.body, summary.level === "error" ? "dialog-error" : "dialog-warning");
        refresh(true);
    }

    function confirmStop(targets, label, detail) {
        confirm.targets = targets;
        confirm.label = label;
        confirm.title = `${label} stoppen?`;
        confirm.subtitle = detail;
        confirm.open();
    }

    function stopGroup(group) {
        const members = group.running.filter(c => !busy[c.id]);
        const label = projectName(group.project);
        confirmStop(members, label, `${members.length} laufende Container des Compose-Projekts werden einzeln mit „docker stop“ angehalten: ${members.map(containerName).join(", ")}. Container, Volumes und Netzwerke bleiben erhalten.`);
    }

    function stopContainer(container) {
        confirmStop([container], containerName(container), `„${container.name}“ wird mit „docker stop“ angehalten. Der Container bleibt erhalten und lässt sich wieder starten.`);
    }

    function toggleGroup(project) {
        const open = openGroups.includes(project) ? openGroups.filter(p => p !== project) : openGroups.concat([project]);
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

    Kirigami.PromptDialog {
        id: confirm
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

    QQC2.Menu {
        id: menu

        property var group: null
        property var container: null
        readonly property bool forContainer: container !== null
        readonly property bool running: forContainer ? Model.isRunning(container) : (group?.running.length ?? 0) > 0
        readonly property bool stopped: forContainer ? !Model.isRunning(container) : group !== null && (group.members.length === 0 || group.running.length < group.members.length)
        readonly property string customKey: forContainer ? `container:${container.name}` : `project:${group?.project ?? ""}`
        readonly property bool isProject: !forContainer && (group?.project ?? "") !== ""

        QQC2.MenuItem {
            text: "Starten"
            icon.name: "media-playback-start"
            // Standalone containers are no unit; each one starts on its own.
            visible: menu.stopped && (menu.forContainer || menu.isProject)
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.act("start", [menu.container], root.containerName(menu.container)) : root.startProject(menu.group)
        }
        QQC2.MenuItem {
            text: "Neu starten"
            icon.name: "view-refresh"
            visible: menu.running && (menu.forContainer || menu.isProject)
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.act("restart", [menu.container], root.containerName(menu.container)) : root.act("restart", menu.group.running, root.projectName(menu.group.project))
        }
        QQC2.MenuItem {
            text: "Stoppen…"
            icon.name: "media-playback-stop"
            visible: menu.running && (menu.forContainer || menu.isProject)
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.stopContainer(menu.container) : root.stopGroup(menu.group)
        }
        QQC2.MenuSeparator {
            visible: menu.forContainer || menu.isProject
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
            text: "Vergessen"
            icon.name: "edit-delete"
            // Docker still lists the project while any container exists; it would come straight back.
            visible: menu.isProject && menu.group.members.length === 0
            height: visible ? implicitHeight : 0
            onTriggered: root.forget(menu.group.project)
        }
        QQC2.MenuItem {
            text: "Aktualisieren"
            icon.name: "view-refresh"
            visible: !menu.forContainer && !menu.isProject
            height: visible ? implicitHeight : 0
            onTriggered: root.refresh(true)
        }
    }

    pageStack.initialPage: Kirigami.ScrollablePage {
        title: root.loaded && !root.error ? `Docker · ${root.runningCount} von ${root.containers.length} laufen` : "Docker"

        actions: [
            Kirigami.Action {
                icon.name: "view-refresh"
                text: "Aktualisieren"
                displayHint: Kirigami.DisplayHint.IconOnly
                tooltip: "Docker-Container aktualisieren (automatisch alle 5 Sekunden)"
                enabled: !root.manualLoading
                onTriggered: root.refresh(true)
            }
        ]

        header: Kirigami.InlineMessage {
            visible: root.error !== ""
            type: Kirigami.MessageType.Error
            position: Kirigami.InlineMessage.Position.Header
            text: root.loaded ? `Docker nicht erreichbar, letzter Stand ist nicht aktuell.\n${root.error}` : `Docker nicht erreichbar. Docker-Dienst und Zugriffsrechte prüfen.\n${root.error}`
        }

        ColumnLayout {
            spacing: 0
            opacity: root.error ? 0.45 : 1

            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.gridUnit * 2
                visible: !root.error && (!root.loaded || root.groups.length === 0)
                icon.name: root.loaded ? "dialog-ok" : ""
                text: root.loaded ? "Keine Container" : "Container werden geladen…"
            }

            Repeater {
                model: root.groups

                delegate: ColumnLayout {
                    id: group

                    required property var modelData
                    readonly property string project: modelData.project
                    readonly property string label: root.projectName(project)
                    readonly property bool isOpen: root.openGroups.includes(project)
                    readonly property bool busy: root.groupBusy(modelData)
                    readonly property bool idle: modelData.running.length === 0
                    readonly property var failedMembers: modelData.members.filter(c => root.failed[c.id])
                    readonly property string worst: Model.groupHealth(modelData.members)
                    // "Einzelne Container" only collects what has no Compose project; it is not a unit to start or stop together.
                    readonly property bool actionable: project !== "" && !busy

                    Layout.fillWidth: true
                    spacing: 0

                    QQC2.ItemDelegate {
                        Layout.fillWidth: true
                        onClicked: root.toggleGroup(group.project)

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
                                visible: !group.busy && group.failedMembers.length > 0
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
                                visible: !group.busy && group.failedMembers.length === 0 && group.worst !== "ok"
                                implicitWidth: 7
                                implicitHeight: 7
                                radius: 4
                                color: group.worst === "unhealthy" ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.neutralTextColor
                            }

                            // Spinner, count and start/stop button share one fixed slot, so hovering never resizes the row.
                            Item {
                                Layout.preferredWidth: Math.max(groupButton.implicitWidth, countLabel.implicitWidth)
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

                                QQC2.Label {
                                    id: countLabel
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !group.busy && !(headerHover.hovered && group.actionable)
                                    horizontalAlignment: Text.AlignRight
                                    text: group.modelData.running.length === group.modelData.members.length ? String(group.modelData.members.length) : `${group.modelData.running.length}/${group.modelData.members.length}`
                                    color: Kirigami.Theme.disabledTextColor
                                }
                            }
                        }
                    }

                    Repeater {
                        model: group.isOpen ? group.modelData.members : []

                        delegate: QQC2.ItemDelegate {
                            id: row

                            required property var modelData
                            readonly property bool running: Model.isRunning(modelData)
                            readonly property bool busy: root.busy[modelData.id] !== undefined || root.busy[`project:${group.project}`] !== undefined
                            readonly property string failure: root.failed[modelData.id] ?? ""
                            readonly property string ownColor: root.custom[`container:${modelData.name}`]?.color ?? ""

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
                                    color: row.ownColor || (row.running ? Kirigami.Theme.textColor : Kirigami.Theme.disabledTextColor)
                                }

                                // Spinner, start/stop button, "!" and uptime share one fixed slot, so hovering never resizes the row.
                                Item {
                                    Layout.preferredWidth: Math.max(rowButton.implicitWidth, uptimeLabel.implicitWidth)
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
                                        visible: !row.busy && rowHover.hovered
                                        icon.name: row.running ? "media-playback-stop" : "media-playback-start"
                                        display: QQC2.AbstractButton.IconOnly
                                        text: row.running ? "Container stoppen" : "Container starten"
                                        QQC2.ToolTip.visible: hovered
                                        QQC2.ToolTip.text: text
                                        onClicked: row.running ? root.stopContainer(row.modelData) : root.act("start", [row.modelData], root.containerName(row.modelData))
                                    }

                                    QQC2.Label {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !row.busy && !rowHover.hovered && row.failure !== ""
                                        text: "!"
                                        font.bold: true
                                        color: Kirigami.Theme.negativeTextColor
                                    }

                                    QQC2.Label {
                                        id: uptimeLabel
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !row.busy && !rowHover.hovered && row.failure === ""
                                        text: Model.uptime(row.modelData.status)
                                        color: Kirigami.Theme.disabledTextColor
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
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
