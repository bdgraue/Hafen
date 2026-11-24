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
    property bool started: false

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
    // Per Docker context: Compose project -> { workingDir, configFiles }. "" is whatever context the CLI uses.
    property var rememberedByContext: JSON.parse(settings.rememberedByContext)
    readonly property var remembered: rememberedByContext[settings.context] ?? {}
    // [{ name, current, endpoint, error }] from `docker context ls`.
    property var contexts: []
    // Folders of a remote daemon are not on this machine.
    readonly property bool localDaemon: {
        const chosen = settings.context ? contexts.find(c => c.name === settings.context) : contexts.find(c => c.current);
        return !chosen || chosen.endpoint.startsWith("unix://");
    }
    // "project:<name>" or "container:<name>" -> { name, color }. Container names survive a recreate, ids do not.
    property var custom: JSON.parse(settings.custom)
    // Container id -> { cpu, mem } from `docker stats`, only while the setting is on and the window is shown.
    property var stats: ({})
    property bool statsLoading: false
    property string statsError: ""
    property var availableUpdate: null
    property bool manualUpdateCheck: false

    // The search filters what the list shows; counts, the tray and the actions keep seeing every container.
    property string query: ""
    readonly property var allGroups: Model.groupContainers(containers, remembered)
    readonly property var groups: Model.filterGroups(allGroups, query, projectName, containerName)
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
    readonly property string logsEnd: qsTr("End of the logs. Enter closes the window.")
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
        if (settings.remembered !== "{}" && rememberedByContext[""] === undefined) {
            rememberedByContext = withKey(rememberedByContext, "", JSON.parse(settings.remembered));
            settings.rememberedByContext = JSON.stringify(rememberedByContext);
            settings.remembered = "{}";
        }
        if (settings.checkUpdates)
            Launcher.checkForUpdate();
        Docker.context = settings.context;
        Docker.startWatching();
        loadContexts();
        started = true;
    }

    Settings {
        id: settings
        objectName: "settings"
        property string openGroups: "[]"
        property string closedSections: "[]"
        // Before 0.3 projects were remembered without a context; read once and moved to rememberedByContext[""].
        property string remembered: "{}"
        property string rememberedByContext: "{}"
        property string context: ""
        property string custom: "{}"
        property string terminal: ""
        property bool showStats: false
        property bool checkUpdates: true
        property bool notifyProblems: true
        property alias windowWidth: root.width
        property alias windowHeight: root.height
    }

    // The tray menu lists every Compose project; stopping asks first, so it brings the window up for the dialog.
    onAllGroupsChanged: tray.setProjects(allGroups.filter(g => g.project).map(g => ({
                project: g.project,
                label: projectName(g.project),
                active: g.active.length > 0,
                canStart: g.members.length === 0 || g.members.some(c => Model.actionsFor(c).start),
                canStop: g.members.some(c => Model.actionsFor(c).stop)
            })))

    Tray {
        id: tray
        objectName: "tray"
        onProjectAction: (project, action) => {
            const group = root.allGroups.find(g => g.project === project);
            if (!group)
                return;
            if (action === "start")
                root.startProject(group);
            else if (action === "restart")
                root.restartProject(group);
            else {
                root.show();
                root.raise();
                root.requestActivate();
                root.stopGroup(group);
            }
        }
        window: root
        warning: root.errorTitle !== "" || root.containers.some(c => Model.condition(c) === "unhealthy")
        subtitle: root.errorTitle ? `${root.errorTitle}\n${root.errorDetail}` : root.loaded ? qsTr("%1 active containers").arg(root.activeCount) : qsTr("Loading containers…")
    }

    Timer {
        interval: Docker.watching ? (root.visible ? Model.WATCHED_REFRESH_MS : Model.WATCHED_HIDDEN_REFRESH_MS) : (root.visible ? Model.REFRESH_MS : Model.HIDDEN_REFRESH_MS)
        // Starts only once Component.onCompleted has set the Docker context, so the first read asks the right daemon.
        running: root.started
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh(false)
    }

    Timer {
        id: eventDebounce
        interval: Model.EVENT_DEBOUNCE_MS
        onTriggered: root.refresh(false)
    }

    Connections {
        target: Docker
        function onContainerEvent(json) {
            eventDebounce.restart();
        }
    }

    Timer {
        interval: Model.STATS_REFRESH_MS
        running: root.started && settings.showStats && root.visible
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
                tray.notify(qsTr("Hafen is up to date"), qsTr("Version %1").arg(Launcher.version), "dialog-information");
            root.manualUpdateCheck = false;
        }
        function onUpdateFailed(message) {
            if (root.manualUpdateCheck)
                tray.notify(qsTr("Checking for updates failed"), message, "dialog-error");
            root.manualUpdateCheck = false;
        }
        function onAutostartFailed(message) {
            tray.notify(qsTr("Autostart could not be changed"), message, "dialog-error");
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
                if (loaded && settings.notifyProblems)
                    announceProblems(Model.problemsBetween(containers, next));
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
                errorTitle = qsTr("Unexpected answer from Docker");
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

    function setRemembered(projects) {
        rememberedByContext = withKey(rememberedByContext, settings.context, projects);
        settings.rememberedByContext = JSON.stringify(rememberedByContext);
    }

    function loadContexts() {
        Docker.run(Model.CONTEXT_ARGS, (code, stdout, stderr) => {
            try {
                if (code !== 0)
                    throw new Error(Model.describeError(code, stderr).title);
                contexts = Model.parseContexts(stdout);
            } catch (e) {
                contexts = [];
                tray.notify(qsTr("Docker contexts could not be read"), String(e.message ?? e), "dialog-warning");
            }
        }, Model.READ_TIMEOUT_MS);
    }

    // Everything shown belongs to the old daemon; start over with the new one.
    function switchContext(name) {
        if (name === settings.context)
            return;
        settings.context = name;
        Docker.context = name;
        containers = [];
        loaded = false;
        stats = {};
        failed = {};
        refresh(true);
    }

    function announceProblems(problems) {
        for (const p of problems) {
            // Hafen's own actions report their outcome themselves.
            if (busy[p.container.id] !== undefined || busy[`project:${p.container.project}`] !== undefined)
                continue;
            const name = containerName(p.container);
            const who = p.container.project ? qsTr("%1 (%2)").arg(name).arg(projectName(p.container.project)) : name;
            if (p.kind === "crashed")
                tray.notify(qsTr("%1 crashed").arg(who), qsTr("The container exited with code %1.").arg(p.code), "dialog-error");
            else if (p.kind === "restarting")
                tray.notify(qsTr("%1 keeps restarting").arg(who), qsTr("The container is stuck in a restart loop."), "dialog-warning");
            else if (p.kind === "dead")
                tray.notify(qsTr("%1 is dead").arg(who), qsTr("Docker could not stop the container cleanly."), "dialog-error");
            else
                tray.notify(qsTr("%1 is unhealthy").arg(who), qsTr("The container's healthcheck fails."), "dialog-warning");
        }
    }

    function remember(sources) {
        const next = Object.assign({}, remembered, sources);
        if (JSON.stringify(next) === JSON.stringify(remembered))
            return;
        setRemembered(next);
    }

    function forget(project) {
        setRemembered(withKey(remembered, project, undefined));
        setCustom(`project:${project}`, undefined);
    }

    function setCustom(key, value) {
        custom = withKey(custom, key, value && (value.name || value.color) ? value : undefined);
        settings.custom = JSON.stringify(custom);
    }

    function projectName(project) {
        return custom[`project:${project}`]?.name || project || qsTr("Standalone containers");
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
                    error: code === 0 ? null : (stderr.trim() || qsTr("Exit code %1").arg(code))
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

    // With the project's Compose files the whole project acts as one, in dependency order; `compose up` also recreates
    // services whose containers are gone. Without them Hafen falls back to one docker call per container.
    function compose(group, action) {
        const label = projectName(group.project);
        const key = `project:${group.project}`;
        if (busy[key])
            return;
        let args;
        try {
            args = Model.composeArgs(group.project, remembered[group.project], Model.COMPOSE_COMMANDS[action]);
        } catch (e) {
            report(action, label, [
                {
                    name: group.project,
                    error: String(e.message ?? e)
                }
            ]);
            return;
        }
        busy = withKey(busy, key, action);
        Docker.run(args, (code, stdout, stderr) => {
            busy = withKey(busy, key, undefined);
            report(action, label, [
                {
                    name: `docker compose ${Model.COMPOSE_COMMANDS[action][0]}`,
                    error: code === 0 ? null : (stderr.trim() || qsTr("Exit code %1").arg(code))
                }
            ]);
        }, Model.NO_TIMEOUT);
    }

    function startProject(group) {
        if (remembered[group.project])
            compose(group, "start");
        else
            act("start", group.members.filter(c => Model.actionsFor(c).start), projectName(group.project));
    }

    function restartProject(group) {
        if (remembered[group.project])
            compose(group, "restart");
        else
            act("restart", group.members.filter(c => Model.actionsFor(c).restart), projectName(group.project));
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
            tray.notify(qsTr("%1 could not be opened").arg(what), problem, "dialog-error");
    }

    function inTerminal(command, what) {
        let prefix;
        try {
            prefix = Model.splitCommand(settings.terminal);
        } catch (e) {
            tray.notify(qsTr("%1 could not be opened").arg(what), String(e.message ?? e), "dialog-error");
            preferences.openSettings();
            return;
        }
        launch(prefix.concat(command), what);
    }

    function confirm(title, detail, buttonText, buttonIcon, onConfirm) {
        stopConfirm.title = title;
        stopConfirm.subtitle = detail;
        stopConfirm.buttonText = buttonText;
        stopConfirm.buttonIcon = buttonIcon;
        stopConfirm.onConfirm = onConfirm;
        stopConfirm.open();
    }

    function stopGroup(group) {
        const label = projectName(group.project);
        if (remembered[group.project]) {
            confirm(qsTr("Stop %1?").arg(label), qsTr("“docker compose stop” stops the Compose project in the order of its dependencies. Containers, volumes and networks are kept."), qsTr("Stop"), "media-playback-stop", () => compose(group, "stop"));
            return;
        }
        const members = group.members.filter(c => Model.actionsFor(c).stop && !busy[c.id]);
        confirm(qsTr("Stop %1?").arg(label), qsTr("Each active container of the Compose project is stopped with “docker stop”: %1. Containers, volumes and networks are kept.").arg(members.map(containerName).join(", ")), qsTr("Stop"), "media-playback-stop", () => act("stop", members, label));
    }

    function downGroup(group) {
        const label = projectName(group.project);
        confirm(qsTr("Shut down %1?").arg(label), qsTr("“docker compose down” stops the project and removes its containers and networks. The data in named volumes is kept; the next start creates the containers again."), qsTr("Shut down"), "system-shutdown-symbolic", () => compose(group, "down"));
    }

    function stopContainer(container) {
        const label = containerName(container);
        confirm(qsTr("Stop %1?").arg(label), qsTr("“%1” is stopped with “docker stop”. The container is kept and can be started again.").arg(container.name), qsTr("Stop"), "media-playback-stop", () => act("stop", [container], label));
    }

    function confirmRemove(targets, label) {
        removeConfirm.targets = targets;
        removeConfirm.label = label;
        removeConfirm.title = targets.length === 1 ? qsTr("Remove %1?").arg(containerName(targets[0])) : qsTr("Remove %1 containers of %2?").arg(targets.length).arg(label);
        removeConfirm.subtitle = qsTr("“docker rm” removes: %1. Images and volumes are kept; a Compose project creates its containers again on the next start.").arg(targets.map(c => c.name).join(", "));
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

    // Project actions act on the whole project, also when the search shows only some of its containers.
    function wholeGroup(group) {
        return group.project ? (allGroups.find(g => g.project === group.project) ?? group) : group;
    }

    // Keyboard navigation: the rows in the order they are shown, as "g:<group key>" and "c:<container id>".
    readonly property var navItems: {
        const items = [];
        for (const section of ["active", "inactive"]) {
            if (query === "" && closedSections.includes(section))
                continue;
            for (const key of layout[section] ?? []) {
                const g = groupByKey[key];
                if (!g)
                    continue;
                items.push(`g:${key}`);
                if (query !== "" || openGroups.includes(key))
                    for (const c of g.members)
                        items.push(`c:${c.id}`);
            }
        }
        return items;
    }
    property string focusKey: ""
    // The highlight belongs to the keyboard: it shows after a key moved it and hides again on a mouse click.
    property bool keyNav: false
    // The highlighted row's delegate, for the context menu's position and for scrolling.
    property var focusItem: null

    function moveFocus(step) {
        if (!navItems.length)
            return;
        const at = navItems.indexOf(focusKey);
        focusKey = navItems[at < 0 ? 0 : Math.max(0, Math.min(navItems.length - 1, at + step))];
    }

    function focusedGroup() {
        return focusKey.startsWith("g:") ? groupByKey[focusKey.slice(2)] ?? null : null;
    }

    function focusedContainer() {
        if (!focusKey.startsWith("c:"))
            return null;
        const id = focusKey.slice(2);
        for (const key in groupByKey) {
            const found = groupByKey[key].members.find(c => c.id === id);
            if (found)
                return {
                    group: groupByKey[key],
                    container: found
                };
        }
        return null;
    }

    function handleKey(event) {
        keyNav = true;
        const group = focusedGroup();
        const hit = focusedContainer();
        switch (event.key) {
        case Qt.Key_Down:
            moveFocus(1);
            break;
        case Qt.Key_Up:
            moveFocus(-1);
            break;
        case Qt.Key_Right:
            if (group && !openGroups.includes(group.key) && query === "")
                toggleGroup(group.key);
            break;
        case Qt.Key_Left:
            if (group && openGroups.includes(group.key) && query === "")
                toggleGroup(group.key);
            else if (hit)
                focusKey = `g:${hit.group.key}`;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (group && query === "")
                toggleGroup(group.key);
            else if (hit)
                openMenu(hit.group, hit.container, focusItem);
            break;
        case Qt.Key_Menu:
            if (group)
                openMenu(group, null, focusItem);
            else if (hit)
                openMenu(hit.group, hit.container, focusItem);
            break;
        case Qt.Key_Delete:
            if (hit && Model.actionsFor(hit.container).remove)
                confirmRemove([hit.container], containerName(hit.container));
            else if (group) {
                const removable = wholeGroup(group).members.filter(c => Model.actionsFor(c).remove);
                if (removable.length)
                    confirmRemove(removable, projectName(group.project));
            }
            break;
        case Qt.Key_L:
            if (hit)
                inTerminal(Model.logsCommand(hit.container, Docker.contextArgs(), logsEnd), qsTr("Logs"));
            else if (group && remembered[group.project])
                inTerminal(Model.projectLogsCommand(group.project, remembered[group.project], Docker.contextArgs(), logsEnd), qsTr("Logs"));
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    function ensureVisible(item) {
        const flick = page.flickable;
        const top = item.mapToItem(flick.contentItem, 0, 0).y;
        if (top < flick.contentY)
            flick.contentY = top;
        else if (top + item.height > flick.contentY + flick.height)
            flick.contentY = top + item.height - flick.height;
    }

    function openMenu(group, container, item) {
        menu.group = wholeGroup(group);
        menu.container = container;
        // "Standalone containers" is no unit: without stopped ones to remove its menu would open empty.
        if (!menu.forContainer && !menu.isProject && menu.removable.length === 0)
            return;
        if (item)
            menu.popup(item);
        else
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
        objectName: "stopConfirm"
        property var onConfirm: null
        property string buttonText: ""
        property string buttonIcon: ""
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: onConfirm()
        onButtonTextChanged: standardButton(Kirigami.Dialog.Ok).text = buttonText
        onButtonIconChanged: standardButton(Kirigami.Dialog.Ok).icon.name = buttonIcon
    }

    Kirigami.PromptDialog {
        id: removeConfirm
        objectName: "removeConfirm"
        property var targets: []
        property string label: ""
        dialogType: Kirigami.PromptDialog.Warning
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: root.act("remove", targets, label)
        // Deleting is not undone by a stray Enter: the dialog opens on Cancel.
        onOpened: standardButton(Kirigami.Dialog.Cancel).forceActiveFocus()
        Component.onCompleted: {
            const ok = standardButton(Kirigami.Dialog.Ok);
            ok.text = qsTr("Remove");
            ok.icon.name = "edit-delete";
        }
    }

    Kirigami.Dialog {
        id: customize
        objectName: "customize"

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

        title: qsTr("Customize %1").arg(original)
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
                objectName: "nameField"
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
                        QQC2.ToolTip.text: modelData ? modelData : qsTr("Default color")
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
        id: diskDialog
        objectName: "diskDialog"

        property var rows: []
        property string error: ""
        property bool loading: false
        property string pruning: ""

        function load() {
            loading = true;
            Docker.run(Model.DISK_USAGE_ARGS, (code, stdout, stderr) => {
                loading = false;
                try {
                    if (code !== 0)
                        throw new Error(Model.describeError(code, stderr).title);
                    rows = Model.parseDiskUsage(stdout);
                    error = "";
                } catch (e) {
                    error = String(e.message ?? e);
                }
            }, Model.READ_TIMEOUT_MS);
        }

        function prune(kind, label) {
            pruning = kind;
            Docker.run(Model.PRUNE[kind], (code, stdout, stderr) => {
                pruning = "";
                if (code === 0)
                    tray.notify(qsTr("%1: cleaned up").arg(label), qsTr("Freed: %1").arg(Model.reclaimed(stdout) ?? qsTr("unknown")), "dialog-information");
                else
                    tray.notify(qsTr("%1: Cleaning up failed").arg(label), stderr.trim() || qsTr("Exit code %1").arg(code), "dialog-error");
                load();
                root.refresh(true);
            }, Model.NO_TIMEOUT);
        }

        function ask(kind, label, detail) {
            root.confirm(qsTr("Clean up %1?").arg(label), detail, qsTr("Clean up"), "edit-clear-all", () => prune(kind, label));
        }

        title: qsTr("Disk usage")
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 26
        standardButtons: Kirigami.Dialog.Close
        onOpened: load()

        ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: diskDialog.error !== ""
                type: Kirigami.MessageType.Error
                text: diskDialog.error
            }

            QQC2.BusyIndicator {
                Layout.alignment: Qt.AlignHCenter
                visible: diskDialog.rows.length === 0 && diskDialog.error === ""
                running: visible
            }

            Repeater {
                model: diskDialog.rows

                delegate: ColumnLayout {
                    id: usage
                    required property var modelData
                    readonly property string label: ({
                            "Images": qsTr("Images"),
                            "Containers": qsTr("Containers"),
                            "Local Volumes": qsTr("Volumes"),
                            "Build Cache": qsTr("Build cache")
                        })[modelData.type] ?? modelData.type
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: qsTr("%1: %2").arg(usage.label).arg(usage.modelData.size)
                            font.bold: true
                        }
                        QQC2.Label {
                            text: qsTr("reclaimable %1").arg(usage.modelData.reclaimable)
                            color: Kirigami.Theme.disabledTextColor
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.Button {
                            visible: usage.modelData.type === "Containers"
                            text: qsTr("Remove stopped containers")
                            enabled: diskDialog.pruning === ""
                            onClicked: diskDialog.ask("containers", qsTr("Stopped containers"), qsTr("“docker container prune” removes every stopped container, also those of stopped Compose projects; their next start creates them again. Volumes are kept."))
                        }
                        QQC2.Button {
                            visible: usage.modelData.type === "Images"
                            text: qsTr("Remove dangling images")
                            enabled: diskDialog.pruning === ""
                            onClicked: diskDialog.ask("danglingImages", qsTr("Dangling images"), qsTr("“docker image prune” removes images without a name that no container uses, mostly leftovers of earlier builds."))
                        }
                        QQC2.Button {
                            visible: usage.modelData.type === "Images"
                            text: qsTr("Remove all unused images")
                            enabled: diskDialog.pruning === ""
                            onClicked: diskDialog.ask("unusedImages", qsTr("Unused images"), qsTr("“docker image prune --all” removes every image no container uses. They have to be pulled or built again on the next start."))
                        }
                        QQC2.Button {
                            visible: usage.modelData.type === "Build Cache"
                            text: qsTr("Clear build cache")
                            enabled: diskDialog.pruning === ""
                            onClicked: diskDialog.ask("buildCache", qsTr("Build cache"), qsTr("“docker builder prune” clears the build cache. The next build takes longer."))
                        }
                        QQC2.Label {
                            visible: usage.modelData.type === "Local Volumes"
                            // A Flow does not wrap the text of a child; the label gets the dialog's width instead.
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: qsTr("Volumes hold data such as databases. Hafen does not remove them.")
                            color: Kirigami.Theme.disabledTextColor
                            font: Kirigami.Theme.smallFont
                        }
                        QQC2.BusyIndicator {
                            visible: diskDialog.pruning !== "" && ({
                                    "containers": "Containers",
                                    "danglingImages": "Images",
                                    "unusedImages": "Images",
                                    "buildCache": "Build Cache"
                                })[diskDialog.pruning] === usage.modelData.type
                            running: visible
                            implicitHeight: Kirigami.Units.iconSizes.small
                            implicitWidth: implicitHeight
                        }
                    }
                }
            }
        }
    }

    Kirigami.Dialog {
        id: preferences
        objectName: "preferences"

        // Read again on every opening, so a terminal installed meanwhile shows up.
        property var terminals: []
        readonly property var chosen: terminals.find(t => t.command === terminalField.text.trim()) ?? null

        function openSettings() {
            terminals = root.findTerminals();
            terminalField.text = settings.terminal;
            root.loadContexts();
            contextBox.chosen = settings.context;
            statsBox.checked = settings.showStats;
            autostartBox.checked = Launcher.autostart;
            updatesBox.checked = settings.checkUpdates;
            problemsBox.checked = settings.notifyProblems;
            open();
        }

        title: qsTr("Settings")
        padding: Kirigami.Units.largeSpacing
        preferredWidth: Kirigami.Units.gridUnit * 24
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            settings.terminal = terminalField.text.trim();
            root.switchContext(contextBox.chosen);
            settings.showStats = statsBox.checked;
            settings.checkUpdates = updatesBox.checked;
            settings.notifyProblems = problemsBox.checked;
            Launcher.autostart = autostartBox.checked;
        }

        // A plain column instead of Kirigami.FormLayout: inside a Kirigami.Dialog the form's size depends on the
        // dialog's and back, which Qt reports as a binding loop every time the dialog opens.
        ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            QQC2.Label {
                visible: contextBox.visible
                text: qsTr("Docker context:")
            }
            QQC2.ComboBox {
                id: contextBox
                objectName: "contextBox"
                // "" follows the context the Docker CLI uses.
                property string chosen: ""
                readonly property var names: [""].concat(root.contexts.map(c => c.name))
                Layout.fillWidth: true
                Layout.bottomMargin: Kirigami.Units.largeSpacing
                visible: root.contexts.length > 1 || settings.context !== ""
                model: names.map(n => n === "" ? qsTr("Same as the Docker CLI") : n)
                currentIndex: Math.max(0, names.indexOf(chosen))
                onActivated: index => chosen = names[index]
            }

            QQC2.Label {
                text: qsTr("Terminal:")
            }
            QQC2.ComboBox {
                Layout.fillWidth: true
                visible: preferences.terminals.length > 0
                model: preferences.terminals.map(t => t.verified ? t.label : qsTr("%1 (option guessed)").arg(t.label)).concat([qsTr("Custom command")])
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
                objectName: "terminalField"
                Layout.fillWidth: true
                placeholderText: qsTr("e.g. konsole -e")
            }
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                text: qsTr("Hafen appends the command for logs or a shell, e.g. “docker exec …”. The terminal has to expect a program with arguments after it.")
            }
            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: preferences.chosen !== null && !preferences.chosen.verified
                type: Kirigami.MessageType.Warning
                text: qsTr("This terminal does not declare the option that runs a command. Hafen assumes “-e”. If logs or a shell do not open, adjust the command.")
            }

            QQC2.CheckBox {
                id: statsBox
                objectName: "statsBox"
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.largeSpacing
                text: qsTr("Show CPU and memory")
            }

            // A checkbox does not wrap its text, so it stays short and the details stand in the label below.
            QQC2.CheckBox {
                id: problemsBox
                objectName: "problemsBox"
                Layout.fillWidth: true
                text: qsTr("Report container problems")
            }
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                text: qsTr("Crashes, restart loops, dead containers and failing healthchecks.")
            }

            QQC2.CheckBox {
                id: autostartBox
                objectName: "autostartBox"
                Layout.fillWidth: true
                text: qsTr("Start in the tray at login")
            }

            QQC2.CheckBox {
                id: updatesBox
                objectName: "updatesBox"
                Layout.fillWidth: true
                text: qsTr("Check for new versions at startup")
            }

            RowLayout {
                Layout.topMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing
                QQC2.Label {
                    Layout.fillWidth: true
                    text: qsTr("Version %1").arg(Launcher.version)
                }
                QQC2.Button {
                    text: qsTr("Check now")
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
        objectName: "menu"

        property var group: null
        property var container: null
        readonly property bool forContainer: container !== null
        // For a group this is the set that offers nothing; never null, the entries below read it while the menu switches.
        readonly property var actions: Model.actionsFor(container ?? {})
        readonly property bool isProject: !forContainer && (group?.project ?? "") !== ""
        // Compose files are known: the project can act as a whole.
        readonly property bool hasCompose: isProject && root.remembered[group.project] !== undefined
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
            text: qsTr("Start")
            icon.name: "media-playback-start"
            visible: menu.canStart
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.act("start", [menu.container], menu.label) : root.startProject(menu.group)
        }
        QQC2.MenuItem {
            text: qsTr("Resume")
            icon.name: "media-playback-start"
            visible: menu.canUnpause
            height: visible ? implicitHeight : 0
            onTriggered: root.act("unpause", menu.forContainer ? [menu.container] : menu.members.filter(c => Model.actionsFor(c).unpause), menu.label)
        }
        QQC2.MenuItem {
            text: qsTr("Restart")
            icon.name: "view-refresh"
            visible: menu.canRestart
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.act("restart", [menu.container], menu.label) : root.restartProject(menu.group)
        }
        QQC2.MenuItem {
            text: qsTr("Stop…")
            icon.name: "media-playback-stop"
            visible: menu.canStop
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.stopContainer(menu.container) : root.stopGroup(menu.group)
        }
        QQC2.MenuItem {
            text: qsTr("Shut down…")
            icon.name: "system-shutdown-symbolic"
            visible: menu.hasCompose && menu.members.length > 0
            height: visible ? implicitHeight : 0
            onTriggered: root.downGroup(menu.group)
        }
        QQC2.MenuSeparator {
            visible: menu.forContainer || menu.hasCompose
            height: visible ? implicitHeight : 0
        }
        QQC2.MenuItem {
            text: menu.forContainer ? qsTr("Show logs") : qsTr("Logs of all containers")
            icon.name: "view-list-text"
            visible: menu.forContainer || menu.hasCompose
            height: visible ? implicitHeight : 0
            onTriggered: menu.forContainer ? root.inTerminal(Model.logsCommand(menu.container, Docker.contextArgs(), root.logsEnd), qsTr("Logs")) : root.inTerminal(Model.projectLogsCommand(menu.group.project, root.remembered[menu.group.project], Docker.contextArgs(), root.logsEnd), qsTr("Logs"))
        }
        QQC2.MenuItem {
            text: qsTr("Open shell")
            icon.name: "utilities-terminal"
            visible: menu.forContainer && menu.actions.shell
            height: visible ? implicitHeight : 0
            onTriggered: root.inTerminal(Model.shellCommand(menu.container, Docker.contextArgs()), qsTr("Shell"))
        }
        QQC2.MenuItem {
            text: qsTr("Open project folder")
            icon.name: "document-open-folder"
            visible: menu.hasCompose && root.localDaemon
            height: visible ? implicitHeight : 0
            onTriggered: root.launch(["xdg-open", root.remembered[menu.group.project].workingDir], qsTr("Project folder"))
        }
        QQC2.MenuSeparator {
            visible: menu.forContainer || menu.isProject || menu.removable.length > 0
            height: visible ? implicitHeight : 0
        }
        QQC2.MenuItem {
            text: qsTr("Name and color…")
            icon.name: "edit-rename"
            visible: menu.forContainer || menu.isProject
            height: visible ? implicitHeight : 0
            onTriggered: customize.openFor(menu.customKey, menu.forContainer ? Model.shortName(menu.container) : menu.group.project)
        }
        QQC2.MenuItem {
            text: qsTr("Reset name and color")
            icon.name: "edit-undo"
            visible: root.custom[menu.customKey] !== undefined
            height: visible ? implicitHeight : 0
            onTriggered: root.setCustom(menu.customKey, undefined)
        }
        QQC2.MenuItem {
            text: menu.forContainer ? qsTr("Remove…") : qsTr("Remove stopped containers…")
            icon.name: "edit-delete"
            visible: menu.forContainer ? menu.actions.remove : menu.removable.length > 0
            height: visible ? implicitHeight : 0
            onTriggered: root.confirmRemove(menu.forContainer ? [menu.container] : menu.removable, menu.label)
        }
        QQC2.MenuItem {
            text: qsTr("Forget")
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
                text: qsTr("Open %1").arg(modelData.url.replace("http://", ""))
                icon.name: "globe"
                onTriggered: root.launch(["xdg-open", modelData.url], qsTr("Browser"))
            }
            onObjectAdded: (index, object) => menu.addItem(object)
            onObjectRemoved: (index, object) => menu.removeItem(object)
        }
    }

    // Ctrl+F needs no shortcut here: Kirigami.SearchField focuses itself on StandardKey.Find, a second one would be ambiguous.
    Shortcut {
        sequence: "F5"
        onActivated: root.refresh(true)
    }

    pageStack.initialPage: Kirigami.ScrollablePage {
        id: page
        objectName: "page"
        // The counts live in the section headers and the tray tooltip; the title names the daemon only.
        title: settings.context ? qsTr("Docker (%1)").arg(settings.context) : "Docker"

        actions: [
            Kirigami.Action {
                icon.name: "view-refresh"
                text: qsTr("Refresh")
                displayHint: Kirigami.DisplayHint.IconOnly
                tooltip: qsTr("Read the containers again now")
                enabled: !root.manualLoading
                onTriggered: root.refresh(true)
            },
            Kirigami.Action {
                icon.name: "drive-harddisk-symbolic"
                text: qsTr("Disk usage")
                displayHint: Kirigami.DisplayHint.IconOnly
                tooltip: qsTr("Show and clean up Docker's disk usage")
                onTriggered: diskDialog.open()
            },
            Kirigami.Action {
                icon.name: "configure"
                text: qsTr("Settings")
                displayHint: Kirigami.DisplayHint.IconOnly
                tooltip: qsTr("Settings")
                onTriggered: preferences.openSettings()
            }
        ]

        header: ColumnLayout {
            spacing: 0

            Kirigami.SearchField {
                id: search
                objectName: "search"
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                placeholderText: qsTr("Filter projects and containers…")
                onTextChanged: root.query = text.trim()
                Keys.onEscapePressed: text = ""
                Keys.onDownPressed: {
                    root.keyNav = true;
                    list.forceActiveFocus();
                    if (!root.navItems.includes(root.focusKey))
                        root.moveFocus(0);
                }
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.errorTitle !== ""
                type: Kirigami.MessageType.Error
                position: Kirigami.InlineMessage.Position.Header
                text: (root.loaded ? qsTr("%1. The list shows the last known state.") : qsTr("%1.")).arg(root.errorTitle) + "\n" + root.errorDetail
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.availableUpdate !== null
                type: Kirigami.MessageType.Information
                position: Kirigami.InlineMessage.Position.Header
                showCloseButton: true
                text: qsTr("Hafen %1 is available.").arg(root.availableUpdate?.tag ?? "")
                actions: [
                    Kirigami.Action {
                        text: qsTr("Download")
                        icon.name: "globe"
                        onTriggered: root.launch(["xdg-open", root.availableUpdate.url], qsTr("Download page"))
                    }
                ]
            }
        }

        footer: QQC2.Label {
            visible: settings.showStats && (root.statsSum !== null || root.statsError !== "")
            padding: Kirigami.Units.smallSpacing * 2
            color: root.statsError ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
            font: Kirigami.Theme.smallFont
            text: root.statsError ? qsTr("CPU/memory: %1").arg(root.statsError) : root.statsSum ? qsTr("Docker in total: CPU %1 · memory %2 (%3)").arg(Model.formatPercent(root.statsSum.cpu)).arg(Model.formatBytes(root.statsSum.mem)).arg(Model.formatPercent(root.statsSum.memShare)) : ""
        }

        ColumnLayout {
            id: list
            objectName: "list"
            spacing: 0
            opacity: root.errorTitle ? 0.45 : 1
            focus: true
            activeFocusOnTab: true
            Keys.onPressed: event => root.handleKey(event)

            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.gridUnit * 2
                visible: !root.errorTitle && (!root.loaded || root.groups.length === 0)
                icon.name: !root.loaded ? "" : root.query ? "edit-find" : "dialog-ok"
                text: !root.loaded ? qsTr("Loading containers…") : root.query ? qsTr("No matches") : qsTr("No containers")
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
                    // While searching every hit is shown, whatever was folded before.
                    readonly property bool isOpen: root.query !== "" || !root.closedSections.includes(key)

                    Layout.fillWidth: true
                    Layout.topMargin: key === "inactive" ? Kirigami.Units.largeSpacing : 0
                    visible: keys.length > 0
                    spacing: 0

                    QQC2.ItemDelegate {
                        Layout.fillWidth: true
                        focusPolicy: Qt.NoFocus
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
                                text: section.key === "active" ? qsTr("Active") : qsTr("Inactive")
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
                            readonly property bool isOpen: root.query !== "" || root.openGroups.includes(modelData.key)
                            readonly property bool busy: root.groupBusy(modelData)
                            readonly property bool idle: modelData.active.length === 0
                            readonly property var failedMembers: modelData.members.filter(c => root.failed[c.id])
                            readonly property string worst: Model.groupHealth(modelData.members)
                            // "Einzelne Container" only collects what has no Compose project; it is not a unit to start or stop together.
                            readonly property bool actionable: project !== "" && !busy

                            Layout.fillWidth: true
                            spacing: 0

                            QQC2.ItemDelegate {
                                objectName: `group:${group.modelData.key}`
                                Layout.fillWidth: true
                                // Arrow keys move this highlight; the list, not the row, keeps keyboard focus.
                                focusPolicy: Qt.NoFocus
                                highlighted: root.keyNav && list.activeFocus && root.focusKey === `g:${group.modelData.key}`
                                onHighlightedChanged: if (highlighted) {
                                    root.focusItem = this;
                                    root.ensureVisible(this);
                                }
                                onClicked: {
                                    root.focusKey = `g:${group.modelData.key}`;
                                    root.keyNav = false;
                                    list.forceActiveFocus();
                                    root.toggleGroup(group.modelData.key);
                                }

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
                                            font.pixelSize: Math.round(parent.height * 0.62)
                                        }
                                        Kirigami.Icon {
                                            anchors.fill: parent
                                            visible: group.project === ""
                                            source: "qrc:/qt/qml/Hafen/data/hafen.svg"
                                        }
                                    }

                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        objectName: "label"
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
                                            objectName: "groupButton"
                                            anchors.centerIn: parent
                                            visible: headerHover.hovered && group.actionable
                                            icon.name: group.idle ? "media-playback-start" : "media-playback-stop"
                                            display: QQC2.AbstractButton.IconOnly
                                            text: group.idle ? qsTr("Start %1").arg(group.label) : qsTr("Stop all containers of %1").arg(group.label)
                                            QQC2.ToolTip.visible: hovered
                                            QQC2.ToolTip.text: text
                                            onClicked: group.idle ? root.startProject(root.wholeGroup(group.modelData)) : root.stopGroup(root.wholeGroup(group.modelData))
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: group.isOpen ? group.modelData.members.length : 0

                                delegate: QQC2.ItemDelegate {
                                    id: row
                                    objectName: `row:${modelData.name}`

                                    focusPolicy: Qt.NoFocus
                                    highlighted: root.keyNav && list.activeFocus && root.focusKey === `c:${modelData.id}`
                                    onHighlightedChanged: if (highlighted) {
                                        root.focusItem = this;
                                        root.ensureVisible(this);
                                    }
                                    onClicked: {
                                        root.focusKey = `c:${modelData.id}`;
                                        root.keyNav = false;
                                        list.forceActiveFocus();
                                    }

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
                                    QQC2.ToolTip.visible: rowHover.hovered && !rowButton.hovered && !menu.visible
                                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                                    QQC2.ToolTip.text: failure ? Model.containerTooltip(modelData) + "\n" + qsTr("Last action failed: %1").arg(failure) : Model.containerTooltip(modelData)

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
                                            objectName: "name"
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
                                            objectName: "stats"
                                            text: settings.showStats ? root.statsText(row.modelData) : ""
                                            color: Kirigami.Theme.disabledTextColor
                                            font: Kirigami.Theme.smallFont
                                        }

                                        QQC2.Label {
                                            objectName: "uptime"
                                            text: row.modelData.state === "paused" ? qsTr("paused") : Model.uptime(row.modelData.status)
                                            color: Kirigami.Theme.disabledTextColor
                                            font: Kirigami.Theme.smallFont
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
                                                objectName: "rowButton"
                                                anchors.centerIn: parent
                                                visible: !row.busy && rowHover.hovered && row.quickAction !== ""
                                                icon.name: row.quickAction === "stop" ? "media-playback-stop" : "media-playback-start"
                                                display: QQC2.AbstractButton.IconOnly
                                                text: row.quickAction === "stop" ? qsTr("Stop container") : row.quickAction === "unpause" ? qsTr("Resume container") : qsTr("Start container")
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
