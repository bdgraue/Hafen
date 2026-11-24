// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

import QtQuick
import QtTest
import org.kde.kirigami as Kirigami
import Hafen

// Drives the real window against the fake docker in bin/. The containers come from scenario.json.
TestCase {
    id: testCase
    name: "Hafen"
    when: true

    readonly property string web: "a1f0c3d2e4b5"
    readonly property string db: "b2e1d4c3f5a6"
    readonly property string mailer: "c3d2e5f4a6b7"
    readonly property string redis: "a7b6c9d8e0f1"
    readonly property string worker: "b8c7d0e9f1a2"
    readonly property string oldJob: "c9d8e1f0a2b3"
    readonly property string shopCompose: "compose --project-name shop --project-directory /srv/shop --file /srv/shop/compose.yaml"

    property var win: null
    property var menu: null
    property var tray: null

    Component {
        id: mainComponent
        Main {}
    }

    SignalSpy {
        id: notified
        signalName: "notified"
    }

    function open(properties) {
        win = createTemporaryObject(mainComponent, testCase, properties ?? {
            startHidden: false
        });
        verify(win);
        tryVerify(() => win.loaded, 5000);
        menu = named("menu");
        tray = named("tray");
        notified.target = tray;
        notified.clear();
    }

    function init() {
        fixture.reset();
        open();
    }

    // Objects with an id in Main.qml carry it as objectName.
    function named(name) {
        const found = findChild(win, name);
        verify(found, `Main.qml has no object named ${name}`);
        return found;
    }

    // Delegates of the list: "group:<key>" and "row:<container name>".
    function item(name) {
        let found = null;
        tryVerify(() => (found = findChild(win.contentItem, name)) !== null, 3000, `no item ${name}`);
        return found;
    }

    function gone(name) {
        tryVerify(() => findChild(win.contentItem, name) === null, 3000, `${name} is still there`);
    }

    // Lets the layouts finish, so that clicks land where the item is now and measurements see the final geometry.
    // Waiting for a frame was not enough: on a loaded machine the frame came before the list had placed new groups,
    // and a click hit the old spot. waitForPolish alone is not enough either: once the list outgrows the view, the
    // scroll bar appears through a posted event and narrows the list in a further polish.
    function settle() {
        for (let round = 0; round < 10; round++) {
            verify(waitForPolish(win, 5000), "the layout did not settle");
            wait(0);
            if (!isPolishScheduled(win))
                return;
        }
        fail("the layout kept changing");
    }

    function openGroup(key) {
        if (!win.openGroups.includes(key)) {
            const header = item(`group:${key}`);
            settle();
            mouseClick(header);
        }
        tryVerify(() => win.openGroups.includes(key));
        settle();
    }

    function row(group, name) {
        openGroup(group);
        const found = item(`row:${name}`);
        settle();
        return found;
    }

    function hover(target) {
        settle();
        mouseMove(target, 20, target.height / 2);
    }

    function rightClick(target) {
        settle();
        mouseClick(target, 20, target.height / 2, Qt.RightButton);
        tryVerify(() => menu.opened, 2000, "the context menu did not open");
    }

    function menuItems() {
        const items = [];
        for (let i = 0; i < menu.count; i++) {
            const entry = menu.itemAt(i);
            if (entry && entry.visible && entry.text !== undefined)
                items.push(entry);
        }
        return items;
    }

    function menuTexts() {
        return menuItems().map(entry => entry.text);
    }

    function choose(text) {
        const entry = menuItems().find(e => e.text === text);
        verify(entry, `the menu has no "${text}", only: ${menuTexts().join(", ")}`);
        mouseClick(entry);
        tryVerify(() => !menu.visible, 2000, "the menu stayed open");
    }

    function closeMenu() {
        menu.close();
        tryVerify(() => !menu.visible, 2000);
    }

    function called(command) {
        tryVerify(() => fixture.calls().includes(command), 3000, `docker was not called with: ${command}\ncalls:\n${fixture.calls().join("\n")}`);
    }

    function neverCalled(part) {
        const hit = fixture.calls().find(c => c.includes(part));
        verify(hit === undefined, `docker was called with: ${hit}`);
    }

    function launchedLast() {
        let all = [];
        tryVerify(() => (all = fixture.launched()).length > 0, 3000, "nothing was launched");
        return all[all.length - 1];
    }

    function container(id) {
        return win.containers.find(c => c.id === id);
    }

    function state(id, expected) {
        tryVerify(() => container(id)?.state === expected, 3000, `${id} is ${container(id)?.state}, not ${expected}`);
    }

    function confirm(dialogName, title) {
        const dialog = named(dialogName);
        tryVerify(() => dialog.opened, 2000, `${dialogName} did not open`);
        compare(dialog.title, title);
        return dialog;
    }

    // Accepts and waits until the dialog is gone: while it fades out it still swallows clicks.
    function accept(dialog) {
        dialog.accept();
        tryVerify(() => !dialog.visible, 2000, "the dialog stayed open");
    }

    function reject(dialog) {
        dialog.reject();
        tryVerify(() => !dialog.visible, 2000, "the dialog stayed open");
    }

    function calledStarting(prefix) {
        tryVerify(() => fixture.calls().some(c => c.startsWith(prefix)), 3000, `docker was not called with: ${prefix}…\ncalls:\n${fixture.calls().join("\n")}`);
    }

    function notification(index) {
        tryVerify(() => notified.count > index, 3000, `only ${notified.count} notifications`);
        return Array.from(notified.signalArguments[index]);
    }

    function findText(parent, text) {
        if (!parent)
            return null;
        if (parent.text === text && parent.visible)
            return parent;
        for (const child of parent.children ?? []) {
            const found = findText(child, text);
            if (found)
                return found;
        }
        return null;
    }

    function keys(section) {
        return win.sections[section].map(g => g.key);
    }

    function test_sections_and_counts() {
        compare(keys("active"), [":standalone-active", "shop", "wiki"]);
        compare(keys("inactive"), [":standalone-inactive", "blog"]);
        compare(tray.subtitle, "5 active containers");
        // wiki-app-1 fails its healthcheck.
        verify(tray.warning);
        compare(named("page").title, "Docker");
        // A paused container is active; its stopped sibling sits in the inactive section.
        compare(win.groupByKey[":standalone-active"].members.map(c => c.name), ["redis-cache", "worker"]);
        compare(win.groupByKey[":standalone-inactive"].members.map(c => c.name), ["old-job"]);
        compare(findChild(row(":standalone-active", "worker"), "uptime").text, "paused");
        compare(findChild(row("shop", "shop-mailer-1"), "uptime").text, "3d");
        compare(findChild(row("shop", "shop-mailer-1"), "name").text, "mailer-1");
    }

    function test_hovering_shows_the_button_without_moving_anything() {
        const target = row("shop", "shop-web-1");
        const name = findChild(target, "name"), uptime = findChild(target, "uptime"), button = findChild(target, "rowButton");
        const geometry = () => [target.height, target.y, name.x, name.width, uptime.x, uptime.visible];
        const before = geometry();
        verify(!button.visible);
        hover(target);
        tryVerify(() => button.visible, 2000, "no button on hover");
        compare(button.text, "Stop container");
        settle();
        compare(geometry(), before);

        const header = item("group:shop");
        const label = findChild(header, "label"), groupButton = findChild(header, "groupButton");
        const headerGeometry = () => [header.height, header.y, label.x, label.width];
        const headerBefore = headerGeometry();
        hover(header);
        tryVerify(() => groupButton.visible, 2000, "no button on the group");
        verify(!button.visible);
        settle();
        compare(headerGeometry(), headerBefore);
    }

    function test_stopping_a_container_asks_first() {
        const target = row("shop", "shop-web-1");
        hover(target);
        mouseClick(findChild(target, "rowButton"));
        let dialog = confirm("stopConfirm", "Stop web-1?");
        reject(dialog);
        neverCalled(`stop ${web}`);

        hover(target);
        mouseClick(findChild(target, "rowButton"));
        dialog = confirm("stopConfirm", "Stop web-1?");
        accept(dialog);
        called(`stop ${web}`);
        state(web, "exited");
        compare(notified.count, 0);
    }

    function test_starting_a_stopped_container_needs_no_confirmation() {
        const target = row("shop", "shop-mailer-1");
        hover(target);
        const button = findChild(target, "rowButton");
        tryVerify(() => button.visible);
        compare(button.text, "Start container");
        mouseClick(button);
        called(`start ${mailer}`);
        state(mailer, "running");
    }

    function test_a_paused_container_resumes_instead_of_starting() {
        const target = row(":standalone-active", "worker");
        hover(target);
        compare(findChild(target, "rowButton").text, "Resume container");
        rightClick(target);
        compare(menuTexts(), ["Resume", "Restart", "Stop…", "Show logs", "Name and color…"]);
        choose("Resume");
        called(`unpause ${worker}`);
        state(worker, "running");
        neverCalled(`start ${worker}`);
    }

    function test_menu_of_a_running_container() {
        rightClick(row("shop", "shop-web-1"));
        compare(menuTexts(), ["Restart", "Stop…", "Show logs", "Open shell", "Name and color…", "Open 127.0.0.1:8080"]);
        choose("Restart");
        called(`restart ${web}`);
    }

    function test_menu_of_a_stopped_container() {
        rightClick(row("shop", "shop-mailer-1"));
        compare(menuTexts(), ["Start", "Show logs", "Name and color…", "Remove…"]);
        closeMenu();
    }

    function test_removing_a_container_starts_on_cancel() {
        rightClick(row("shop", "shop-mailer-1"));
        choose("Remove…");
        const dialog = confirm("removeConfirm", "Remove mailer-1?");
        tryVerify(() => dialog.standardButton(Kirigami.Dialog.Cancel).activeFocus, 2000, "Cancel does not have the focus");
        accept(dialog);
        called(`rm ${mailer}`);
        gone("row:shop-mailer-1");
        neverCalled("--force");
        neverCalled("--volumes");
    }

    function test_logs_and_shell_open_in_the_terminal() {
        const target = row("shop", "shop-web-1");
        rightClick(target);
        choose("Show logs");
        compare(launchedLast(), ["fake-terminal", "-e", "sh", "-c", '"$@"; printf "\\n— %s —" "$0"; read -r _', "End of the logs. Enter closes the window.", "docker", "logs", "--follow", "--tail", "200", web]);
        rightClick(target);
        choose("Open shell");
        tryVerify(() => fixture.launched().length === 2);
        compare(launchedLast(), ["fake-terminal", "-e", "docker", "exec", "--interactive", "--tty", web, "sh", "-c", "[ -x /bin/bash ] && exec bash || exec sh"]);
    }

    function test_without_a_terminal_the_settings_open() {
        named("settings").terminal = "";
        rightClick(row("shop", "shop-web-1"));
        choose("Show logs");
        compare(notification(0)[0], "Logs could not be opened");
        tryVerify(() => named("preferences").opened);
        compare(fixture.launched().length, 0);
    }

    function test_a_published_port_opens_in_the_browser() {
        rightClick(row("shop", "shop-web-1"));
        choose("Open 127.0.0.1:8080");
        compare(launchedLast(), ["xdg-open", "http://127.0.0.1:8080"]);
    }

    function test_menu_of_a_compose_project() {
        const header = item("group:shop");
        rightClick(header);
        compare(menuTexts(), ["Start", "Restart", "Stop…", "Shut down…", "Logs of all containers", "Open project folder", "Name and color…", "Remove stopped containers…"]);
        choose("Restart");
        called(`${shopCompose} restart`);

        rightClick(header);
        choose("Logs of all containers");
        compare(launchedLast().slice(6), ["docker", "compose", "--project-name", "shop", "--project-directory", "/srv/shop", "--file", "/srv/shop/compose.yaml", "logs", "--follow", "--tail", "200"]);

        rightClick(header);
        choose("Open project folder");
        tryVerify(() => fixture.launched().length === 2);
        compare(launchedLast(), ["xdg-open", "/srv/shop"]);
    }

    function test_standalone_containers_are_no_unit() {
        const header = item("group::standalone-active");
        hover(header);
        wait(150);
        verify(!findChild(header, "groupButton").visible);
        // Nothing to offer: no empty menu pops up.
        mouseClick(header, 20, header.height / 2, Qt.RightButton);
        wait(300);
        verify(!menu.visible);
        // The stopped ones can be removed together.
        rightClick(item("group::standalone-inactive"));
        compare(menuTexts(), ["Remove stopped containers…"]);
        choose("Remove stopped containers…");
        accept(confirm("removeConfirm", "Remove old-job?"));
        called(`rm ${oldJob}`);
    }

    function test_stopping_a_project_uses_compose() {
        const header = item("group:wiki");
        hover(header);
        const button = findChild(header, "groupButton");
        tryVerify(() => button.visible);
        compare(button.text, "Stop all containers of wiki");
        mouseClick(button);
        accept(confirm("stopConfirm", "Stop wiki?"));
        // Both Compose files of the project are passed on.
        called("compose --project-name wiki --project-directory /srv/wiki --file /srv/wiki/compose.yaml --file /srv/wiki/compose.override.yaml stop");
        tryVerify(() => keys("inactive").includes("wiki"), 3000);
        neverCalled("stop d4e3f6a5b7c8");
    }

    function test_starting_an_inactive_project_uses_compose_up() {
        const header = item("group:blog");
        hover(header);
        const button = findChild(header, "groupButton");
        tryVerify(() => button.visible);
        compare(button.text, "Start blog");
        mouseClick(button);
        called("compose --project-name blog --project-directory /srv/blog --file /srv/blog/compose.yaml up --detach");
        tryVerify(() => keys("active").includes("blog"), 3000);
    }

    function test_a_project_survives_compose_down_and_can_be_forgotten() {
        rightClick(item("group:shop"));
        choose("Shut down…");
        accept(confirm("stopConfirm", "Shut down shop?"));
        called(`${shopCompose} down`);
        neverCalled("--volumes");
        tryVerify(() => win.groupByKey["shop"]?.members.length === 0, 3000, "the containers are still listed");
        verify(keys("inactive").includes("shop"));

        // Remembered: it starts again although Docker lists nothing of it.
        const header = item("group:shop");
        hover(header);
        const button = findChild(header, "groupButton");
        tryVerify(() => button.visible);
        mouseClick(button);
        called(`${shopCompose} up --detach`);
        tryVerify(() => win.groupByKey["shop"]?.members.length === 3, 3000);

        rightClick(item("group:shop"));
        choose("Shut down…");
        accept(confirm("stopConfirm", "Shut down shop?"));
        tryVerify(() => win.groupByKey["shop"]?.members.length === 0, 3000);
        rightClick(item("group:shop"));
        compare(menuTexts(), ["Start", "Logs of all containers", "Open project folder", "Name and color…", "Forget"]);
        choose("Forget");
        gone("group:shop");
        verify(!keys("inactive").includes("shop"));
    }

    function test_a_failed_action_is_reported() {
        fixture.failCommand(`stop ${web}`, "Error response from daemon: boom\nsecond line");
        const target = row("shop", "shop-web-1");
        hover(target);
        mouseClick(findChild(target, "rowButton"));
        accept(confirm("stopConfirm", "Stop web-1?"));
        compare(notification(0), ["web-1: Stopping failed", "shop-web-1: Error response from daemon: boom", "dialog-error"]);
        compare(win.failed[web], "Error response from daemon: boom\nsecond line");
        state(web, "running");
        verify(win.busy[web] === undefined);
    }

    function test_search_filters_and_unfolds() {
        const search = named("search");
        search.text = "blog";
        compare(win.groups.map(g => g.project), ["blog"]);
        item("row:blog-web-1");
        gone("group:shop");

        search.text = "shop web";
        compare(win.groups.map(g => [g.project, g.members.map(c => c.name)]), [["shop", ["shop-web-1"]]]);
        // The project still acts as a whole.
        rightClick(item("group:shop"));
        verify(menuTexts().includes("Remove stopped containers…"));
        closeMenu();

        search.text = "nothing like this";
        compare(win.groups.length, 0);
        tryVerify(() => findText(win.contentItem, "No matches") !== null);

        search.text = "";
        compare(win.groups.map(g => g.project), ["", "blog", "shop", "wiki"]);
        // Folded again as before the search.
        gone("row:blog-web-1");
    }

    function test_keyboard() {
        win.requestActivate();
        tryVerify(() => win.active, 2000, "the window is not active");
        const list = named("list");
        list.forceActiveFocus();
        tryVerify(() => list.activeFocus);

        keyClick(Qt.Key_Down);
        compare(win.focusKey, "g::standalone-active");
        tryVerify(() => item("group::standalone-active").highlighted);
        keyClick(Qt.Key_Right);
        verify(win.openGroups.includes(":standalone-active"));
        keyClick(Qt.Key_Down);
        compare(win.focusKey, `c:${redis}`);
        tryVerify(() => item("row:redis-cache").highlighted);

        keyClick(Qt.Key_L);
        compare(launchedLast().slice(-6), ["docker", "logs", "--follow", "--tail", "200", redis]);
        // Docker refuses to remove a running container, so Delete offers nothing.
        keyClick(Qt.Key_Delete);
        wait(150);
        verify(!named("removeConfirm").opened);

        keyClick(Qt.Key_Return);
        tryVerify(() => menu.opened, 2000, "Enter did not open the menu");
        closeMenu();

        keyClick(Qt.Key_Left);
        compare(win.focusKey, "g::standalone-active");
        keyClick(Qt.Key_Left);
        verify(!win.openGroups.includes(":standalone-active"));
        keyClick(Qt.Key_Up);
        compare(win.focusKey, "g::standalone-active");
        keyClick(Qt.Key_Down);
        compare(win.focusKey, "g:shop");
        keyClick(Qt.Key_Space);
        verify(win.openGroups.includes("shop"));

        // A mouse click moves the cursor but hides the highlight until the next key.
        const target = row(":standalone-inactive", "old-job");
        mouseClick(target);
        compare(win.focusKey, `c:${oldJob}`);
        verify(!target.highlighted);
        keyClick(Qt.Key_Delete);
        reject(confirm("removeConfirm", "Remove old-job?"));
        tryVerify(() => !named("removeConfirm").visible);

        const before = fixture.calls().filter(c => c.startsWith("ps ")).length;
        keyClick(Qt.Key_F5);
        tryVerify(() => fixture.calls().filter(c => c.startsWith("ps ")).length > before, 2000, "F5 did not read again");

        keyClick(Qt.Key_F, Qt.ControlModifier);
        tryVerify(() => named("search").activeFocus, 2000, "Ctrl+F did not focus the search");
        keyClick(Qt.Key_Down);
        tryVerify(() => list.activeFocus, 2000, "Down did not leave the search");
    }

    function test_cpu_and_memory_are_opt_in() {
        neverCalled("stats");
        const preferences = named("preferences");
        preferences.openSettings();
        tryVerify(() => preferences.opened);
        named("statsBox").checked = true;
        accept(preferences);
        verify(named("settings").showStats);
        called("stats --no-stream --format {\"id\":{{json .ID}},\"cpu\":{{json .CPUPerc}},\"mem\":{{json .MemUsage}}}");
        const target = row("shop", "shop-web-1");
        tryCompare(findChild(target, "stats"), "text", "13 % · 256 MiB", 3000);
        verify(win.statsSum.mem > 0);
        compare(findChild(row("shop", "shop-mailer-1"), "stats").text, "");

        named("settings").showStats = false;
        tryVerify(() => Object.keys(win.stats).length === 0);
        compare(findChild(target, "stats").text, "");
    }

    function test_autostart_writes_and_removes_the_desktop_file() {
        const file = "config/autostart/hafen.desktop";
        const preferences = named("preferences");
        preferences.openSettings();
        verify(!named("autostartBox").checked);
        named("autostartBox").checked = true;
        accept(preferences);
        tryVerify(() => fixture.exists(file));
        verify(fixture.read(file).includes(" --hidden\n"));
        verify(fixture.read(file).includes("Type=Application"));

        preferences.openSettings();
        verify(named("autostartBox").checked);
        named("autostartBox").checked = false;
        accept(preferences);
        tryVerify(() => !fixture.exists(file));
    }

    function test_settings_keep_the_terminal_command() {
        const preferences = named("preferences");
        preferences.openSettings();
        compare(named("terminalField").text, "fake-terminal -e");
        named("terminalField").text = "  fake-terminal --title 'Hafen logs' -e ";
        accept(preferences);
        compare(named("settings").terminal, "fake-terminal --title 'Hafen logs' -e");
        rightClick(row("shop", "shop-web-1"));
        choose("Open shell");
        compare(launchedLast().slice(0, 5), ["fake-terminal", "--title", "Hafen logs", "-e", "docker"]);
    }

    function test_disk_usage_and_cleanup() {
        const dialog = named("diskDialog");
        dialog.open();
        tryVerify(() => dialog.rows.length === 4, 3000);
        compare(dialog.rows.map(r => r.type), ["Images", "Containers", "Local Volumes", "Build Cache"]);
        verify(findText(dialog.contentItem, "Images: 4.2GB"));
        verify(findText(dialog.contentItem, "Volumes hold data such as databases. Hafen does not remove them."));

        settle();
        mouseClick(findText(dialog.contentItem, "Remove stopped containers"));
        accept(confirm("stopConfirm", "Clean up Stopped containers?"));
        called("container prune --force");
        compare(notification(0), ["Stopped containers: cleaned up", "Freed: 80MB", "dialog-information"]);
        tryVerify(() => win.containers.every(c => c.state !== "exited"), 3000);

        mouseClick(findText(dialog.contentItem, "Clear build cache"));
        accept(confirm("stopConfirm", "Clean up Build cache?"));
        called("builder prune --force");
        compare(notification(1).slice(0, 2), ["Build cache: cleaned up", "Freed: 5.6GB"]);

        mouseClick(findText(dialog.contentItem, "Remove dangling images"));
        accept(confirm("stopConfirm", "Clean up Dangling images?"));
        called("image prune --force");
        mouseClick(findText(dialog.contentItem, "Remove all unused images"));
        accept(confirm("stopConfirm", "Clean up Unused images?"));
        called("image prune --all --force");
        neverCalled("volume");
    }

    function test_another_docker_context() {
        fixture.setContexts([
            {
                Name: "default",
                Current: true,
                DockerEndpoint: "unix:///var/run/docker.sock",
                Error: ""
            },
            {
                Name: "remote",
                Current: false,
                DockerEndpoint: "ssh://box",
                Error: ""
            },
        ]);
        const preferences = named("preferences"), box = named("contextBox");
        preferences.openSettings();
        tryVerify(() => win.contexts.length === 2, 3000);
        verify(box.visible);
        compare(box.model, ["Same as the Docker CLI", "default", "remote"]);
        box.activated(2);
        accept(preferences);

        compare(named("settings").context, "remote");
        compare(named("page").title, "Docker (remote)");
        calledStarting("--context remote ps --all ");
        calledStarting("--context remote events ");
        tryVerify(() => win.loaded);

        // The projects of this daemon are remembered under its context.
        tryVerify(() => win.rememberedByContext["remote"]?.shop !== undefined, 3000);
        rightClick(item("group:shop"));
        // The folder is on the other machine.
        verify(!menuTexts().includes("Open project folder"));
        choose("Logs of all containers");
        compare(launchedLast().slice(6, 10), ["docker", "--context", "remote", "compose"]);
    }

    function test_changes_from_outside_arrive_through_docker_events() {
        tryVerify(() => Docker.watching, 2000, "docker events is not connected");
        const reads = fixture.calls().filter(c => c.startsWith("ps ")).length;
        fixture.patchContainer(redis, {
            state: "exited",
            status: "Exited (0) 1 second ago"
        });
        // Polling would take 30 seconds while the stream is connected.
        state(redis, "exited");
        verify(fixture.calls().filter(c => c.startsWith("ps ")).length > reads);
        tryVerify(() => keys("active").includes(":standalone-active") && win.groupByKey[":standalone-active"].members.length === 1);
        // An exit code of `docker stop` is no crash.
        compare(notified.count, 0);
        compare(tray.subtitle, "4 active containers");
    }

    function test_problems_are_reported_once() {
        fixture.patchContainer(redis, {
            state: "exited",
            status: "Exited (3) 1 second ago"
        });
        compare(notification(0), ["redis-cache crashed", "The container exited with code 3.", "dialog-error"]);
        fixture.patchContainer(db, {
            state: "restarting",
            status: "Restarting (1) 2 seconds ago"
        });
        compare(notification(1), ["db-1 (shop) keeps restarting", "The container is stuck in a restart loop.", "dialog-warning"]);
        fixture.patchContainer(web, {
            status: "Up 2 hours (unhealthy)"
        });
        compare(notification(2), ["web-1 (shop) is unhealthy", "The container's healthcheck fails.", "dialog-warning"]);
        // Still unhealthy on the next read: no second notification.
        fixture.patchContainer(web, {
            status: "Up 3 hours (unhealthy)"
        });
        tryVerify(() => container(web).status === "Up 3 hours (unhealthy)", 3000);
        compare(notified.count, 3);

        named("settings").notifyProblems = false;
        fixture.patchContainer(worker, {
            state: "dead",
            status: "Dead"
        });
        state(worker, "dead");
        compare(notified.count, 3);
    }

    function test_name_and_color_are_hafens_own() {
        const header = item("group:shop");
        rightClick(header);
        choose("Name and color…");
        const dialog = confirm("customize", "Customize shop");
        named("nameField").text = " Webshop ";
        dialog.chosenColor = "#e05252";
        accept(dialog);
        compare(findChild(header, "label").text, "Webshop");
        compare(win.projectColor("shop"), "#e05252");
        compare(JSON.parse(named("settings").custom), {
            "project:shop": {
                name: "Webshop",
                color: "#e05252"
            }
        });
        // Docker still knows the project by its own name.
        rightClick(header);
        choose("Restart");
        called(`${shopCompose} restart`);

        const target = row("shop", "shop-mailer-1");
        rightClick(target);
        choose("Name and color…");
        confirm("customize", "Customize mailer-1");
        named("nameField").text = "Postfach";
        accept(named("customize"));
        compare(findChild(target, "name").text, "Postfach");

        rightClick(header);
        choose("Reset name and color");
        compare(findChild(header, "label").text, "shop");
        verify(win.projectColor("shop") !== "#e05252");
    }

    function test_an_unreachable_daemon_is_named_and_recovers() {
        fixture.setDaemonDown(true);
        win.refresh(true);
        tryCompare(win, "errorTitle", "The Docker daemon is not running", 3000);
        verify(tray.warning);
        verify(tray.subtitle.startsWith("The Docker daemon is not running\n"));
        // The last known list stays visible.
        compare(win.containers.length, 9);
        verify(findText(win.contentItem, "The Docker daemon is not running. The list shows the last known state.\n" + win.errorDetail));

        fixture.setDaemonDown(false);
        win.refresh(true);
        tryCompare(win, "errorTitle", "", 3000);
        compare(tray.subtitle, "5 active containers");
    }

    function test_tray_menu_actions() {
        tray.projectAction("blog", "start");
        called("compose --project-name blog --project-directory /srv/blog --file /srv/blog/compose.yaml up --detach");
        tray.projectAction("shop", "restart");
        called(`${shopCompose} restart`);
        win.hide();
        verify(!win.visible);
        // Stopping asks first, so the window comes up for the question.
        tray.projectAction("shop", "stop");
        tryVerify(() => win.visible);
        accept(confirm("stopConfirm", "Stop shop?"));
        called(`${shopCompose} stop`);
    }

    function test_closing_only_hides() {
        win.close();
        tryVerify(() => !win.visible);
        // Still alive and reading.
        fixture.patchContainer(redis, {
            state: "exited",
            status: "Exited (0) 1 second ago"
        });
        state(redis, "exited");
    }

    function test_hidden_start_shows_no_window() {
        win.destroy();
        open({
            startHidden: true
        });
        verify(!win.visible);
        compare(tray.subtitle, "5 active containers");
    }

    // Every control of a dialog ends inside the dialog, also in the small default window.
    function fits(dialog) {
        tryVerify(() => dialog.opened, 2000);
        const content = dialog.contentItem.contentChildren[0];
        settle();
        verify(content.width > 0 && content.height > 0, `${dialog.objectName} has no content`);
        const check = node => {
            if (!node.visible)
                return;
            if (node.width > 0 && node !== content) {
                const right = node.mapToItem(content, node.width, 0).x;
                verify(right <= content.width + 1, `${dialog.objectName}: ${node} "${node.text ?? ""}" ends at ${right}, the content at ${content.width}`);
            }
            // Controls clip or elide their own inside; only what the layout places counts.
            if (node.text !== undefined && node !== content)
                return;
            for (const child of node.children ?? [])
                check(child);
        };
        check(content);
        verify(dialog.width <= win.width && dialog.height <= win.height, `${dialog.objectName} is ${dialog.width}×${dialog.height}, the window ${win.width}×${win.height}`);
    }

    function test_dialogs_fit_the_default_window() {
        compare([win.width, win.height], [340, 540]);
        named("preferences").openSettings();
        fits(named("preferences"));
        reject(named("preferences"));

        named("diskDialog").open();
        tryVerify(() => named("diskDialog").rows.length === 4, 3000);
        fits(named("diskDialog"));
        named("diskDialog").close();
        tryVerify(() => !named("diskDialog").visible);

        named("customize").openFor("project:shop", "shop");
        fits(named("customize"));
    }

    function test_screenshots() {
        // Tall enough for the dialogs; test_dialogs_fit_the_default_window covers the default size.
        win.height = 820;
        row("shop", "shop-web-1");
        row(":standalone-active", "worker");
        hover(item("row:shop-db-1"));
        wait(200);
        grabImage(win.contentItem).save(fixture.artifact("list.png"));

        rightClick(item("row:shop-web-1"));
        wait(200);
        grabImage(win.contentItem).save(fixture.artifact("menu.png"));
        closeMenu();

        named("settings").showStats = true;
        tryVerify(() => Object.keys(win.stats).length > 0, 3000);
        wait(200);
        grabImage(win.contentItem).save(fixture.artifact("stats.png"));

        named("preferences").openSettings();
        wait(400);
        grabImage(win.contentItem).save(fixture.artifact("settings.png"));
        reject(named("preferences"));

        named("diskDialog").open();
        tryVerify(() => named("diskDialog").rows.length === 4, 3000);
        wait(400);
        grabImage(win.contentItem).save(fixture.artifact("disk.png"));
        named("diskDialog").close();
        tryVerify(() => !named("diskDialog").visible);

        // Opened directly: the menu entry's text depends on the language of the screenshots.
        named("customize").openFor("project:shop", "shop");
        wait(400);
        grabImage(win.contentItem).save(fixture.artifact("customize.png"));
    }
}
