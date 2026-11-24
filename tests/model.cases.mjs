// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

// The tests of src/model.mjs, written against an injected `assert` (equal, deepEqual, throws, match) so the same
// cases run under Node (tests/model.test.mjs) and inside Qt's JavaScript engine (tests/ui/tst_model.qml).
// Only what both engines understand belongs in here.
import {
  COMPOSE_COMMANDS, NOT_STARTED, PRUNE, actionArgs, actionSummary, actionsFor, composeArgs, composeSources,
  composeUpArgs, condition, containerTooltip, describeError, exitCode, filterGroups, formatBytes, formatPercent,
  groupContainers, groupHealth, isNewer, logsCommand, parseContainers, parseContexts, parseDesktopEntry,
  parseDiskUsage, parseSize, parseStats, problemsBetween, projectLogsCommand, publishedPorts, reclaimed,
  shellCommand, shortName, splitCommand, splitSections, statsTotal, statusColor, stripFieldCodes, terminalCandidates,
  uptime,
} from "../src/model.mjs";

export const cases = {};


const container = (id, project = "", status = "Up 2 hours", state = "running") => ({
  id, name: project ? `${project}-${id}` : `container-${id}`, image: "example:latest", status, state,
  ports: "127.0.0.1:8080->80/tcp", project,
  workingDir: project ? `/srv/${project}` : "", configFiles: project ? `/srv/${project}/compose.yaml,/srv/${project}/compose.override.yaml` : "",
});
const ndjson = containers => containers.map(row => JSON.stringify(row)).join("\n");
const colors = { blocked: "red", working: "amber", done: "green", stopped: "grey" };

cases["parses Docker NDJSON, sorts and groups Compose projects and standalone containers"] = assert => {
  const rows = parseContainers(`\n${ndjson([container("z", "shop"), container("x"), container("a", "shop", "Exited (0) 3 days ago", "exited")])}\r\n`);
  assert.deepEqual(rows.map(row => row.id), ["x", "a", "z"]);
  const groups = groupContainers(rows);
  assert.deepEqual(groups.map(g => [g.project, g.members.length, g.active.length]), [["", 1, 1], ["shop", 2, 1]]);
  assert.deepEqual(parseContainers("\n"), []);
  assert.throws(() => parseContainers("not json"));
  assert.throws(() => parseContainers('{"id":"incomplete"}'), /Docker/);
};

cases["remembered projects without containers keep an empty group"] = assert => {
  const groups = groupContainers([container("a", "shop")], { blog: { workingDir: "/srv/blog", configFiles: ["/srv/blog/compose.yaml"] } });
  assert.deepEqual(groups.map(g => [g.project, g.members.length]), [["blog", 0], ["shop", 1]]);
};

cases["projects with any running container are active, standalone containers split by state"] = assert => {
  const exited = id => container(id, "", "Exited (0) 1 day ago", "exited");
  const groups = groupContainers([
    container("a", "shop"), container("b", "shop", "Exited (0) 1 day ago", "exited"),
    container("c", "blog", "Exited (0) 1 day ago", "exited"), container("x"), exited("y"),
  ], { wiki: { workingDir: "/srv/wiki", configFiles: ["/srv/wiki/compose.yaml"] } });
  const { active, inactive } = splitSections(groups);
  assert.deepEqual(active.map(g => [g.key, g.members.map(c => c.id)]), [[":standalone-active", ["x"]], ["shop", ["a", "b"]]]);
  assert.deepEqual(inactive.map(g => [g.key, g.members.map(c => c.id)]), [[":standalone-inactive", ["y"]], ["blog", ["c"]], ["wiki", []]]);
};

cases["compose sources come from the labels and build a compose up command"] = assert => {
  const sources = composeSources([container("a", "shop"), container("x")]);
  assert.deepEqual(sources, { shop: { workingDir: "/srv/shop", configFiles: ["/srv/shop/compose.yaml", "/srv/shop/compose.override.yaml"] } });
  assert.deepEqual(composeUpArgs("shop", sources.shop), [
    "compose", "--project-name", "shop", "--project-directory", "/srv/shop",
    "--file", "/srv/shop/compose.yaml", "--file", "/srv/shop/compose.override.yaml", "up", "--detach",
  ]);
  assert.deepEqual(composeArgs("shop", sources.shop, COMPOSE_COMMANDS.down).slice(-1), ["down"]);
  assert.deepEqual(composeArgs("shop", sources.shop, COMPOSE_COMMANDS.stop).slice(-1), ["stop"]);
  assert.throws(() => actionArgs("down", "abc"), /Compose/);
  assert.throws(() => composeUpArgs("blog", undefined), /blog/);
  assert.throws(() => composeUpArgs("blog", { workingDir: "/srv/blog", configFiles: [] }), /blog/);
};

cases["health colors, compact names, uptime and tooltip"] = assert => {
  assert.equal(statusColor(container("a", "", "Up 1 hour (unhealthy)"), colors), "red");
  assert.equal(statusColor(container("a", "", "Up 1 minute (health: starting)"), colors), "amber");
  assert.equal(statusColor(container("a", "", "Up 1 hour (healthy)"), colors), "green");
  assert.equal(statusColor(container("a", "", "Exited (0) 2 hours ago", "exited"), colors), "grey");
  assert.equal(groupHealth([container("a", "", "Up 1 hour (health: starting)"), container("b", "", "Up (unhealthy)")]), "unhealthy");
  assert.equal(groupHealth([container("b", "", "Exited (1) 1 hour ago (unhealthy)", "exited")]), "ok");
  assert.equal(shortName(container("web-1", "shop")), "web-1");
  assert.equal(shortName({ name: "shop", project: "shop" }), "shop");
  assert.equal(shortName(container("a")), "container-a");
  for (const [raw, short] of [["Up 2 days (healthy)", "2d"], ["Up 7 hours", "7h"], ["Up 46 minutes", "46m"], ["Up 1 second", "1s"], ["Up 3 weeks", "3w"],
    ["Up 2 months", "2mo"], ["Up 1 year", "1y"], ["Up About an hour", "~1h"], ["Up Less than a second", "<1s"],
    ["Up 5 hours (health: starting)", "5h"], ["Exited (0) 3 days ago", "3d"], ["Exited (137) 2 weeks ago", "2w"],
    ["Created", "Created"], ["Up Something new", "Something new"]]) assert.equal(uptime(raw), short, raw);
  assert.match(containerTooltip(container("a")), /127\.0\.0\.1:8080->80\/tcp/);
};

cases["action summary stays quiet on success and names partial and total failures"] = assert => {
  const ok = { name: "shop-a", error: null };
  const bad = { name: "shop-b", error: "Error response from daemon: boom\nmore" };
  assert.equal(actionSummary("stop", "shop", [ok]), null);
  assert.deepEqual(actionSummary("stop", "shop", [ok, bad]), { title: "shop: 1 of 2 containers stopped", body: "shop-b: Error response from daemon: boom", level: "warning" });
  assert.equal(actionSummary("start", "shop", [bad]).title, "shop: Starting failed");
  assert.equal(actionSummary("restart", "shop", [bad]).level, "error");
  assert.throws(() => actionSummary("pause", "shop", [bad]), /pause/);
};

cases["Docker's state machine decides what is offered"] = assert => {
  const of = state => actionsFor(container("a", "", "x", state));
  assert.deepEqual([of("running").start, of("running").stop, of("running").remove, of("running").shell], [false, true, false, true]);
  assert.deepEqual([of("paused").start, of("paused").unpause, of("paused").active, of("paused").remove], [false, true, true, false]);
  assert.deepEqual([of("restarting").active, of("restarting").stop, of("restarting").remove], [true, true, false]);
  assert.deepEqual([of("exited").start, of("exited").remove, of("exited").active], [true, true, false]);
  assert.deepEqual([of("dead").start, of("dead").remove], [false, true]);
  assert.deepEqual(Object.values(of("something-new")).filter(Boolean), []);
  assert.equal(condition(container("a", "", "Restarting (1) 3 seconds ago", "restarting")), "unhealthy");
  assert.equal(condition(container("a", "", "Dead", "dead")), "unhealthy");
  assert.equal(condition(container("a", "", "Up 2 hours (Paused)", "paused")), "starting");
  assert.equal(statusColor(container("a", "", "Up 2 hours (Paused)", "paused"), colors), "amber");
  assert.equal(uptime("Restarting (1) 3 seconds ago"), "3s");
  assert.deepEqual(actionArgs("remove", "abc"), ["rm", "abc"]);
  assert.deepEqual(actionArgs("unpause", "abc"), ["unpause", "abc"]);
  assert.throws(() => actionArgs("kill", "abc"), /kill/);
};

cases["paused and restarting containers keep a project active"] = assert => {
  const groups = groupContainers([container("a", "shop", "Up 1 hour (Paused)", "paused"), container("b", "blog", "Restarting (1) 1 second ago", "restarting")]);
  assert.deepEqual(splitSections(groups).active.map(g => g.key), ["blog", "shop"]);
};

cases["published TCP ports become browser URLs"] = assert => {
  assert.deepEqual(publishedPorts("0.0.0.0:80->80/tcp, [::]:80->80/tcp, 0.0.0.0:443->443/tcp, 1025/tcp"),
    [{ port: 80, url: "http://127.0.0.1:80" }, { port: 443, url: "http://127.0.0.1:443" }]);
  assert.deepEqual(publishedPorts("127.0.0.1:53535->53/tcp, 127.0.0.1:53535->53/udp"), [{ port: 53535, url: "http://127.0.0.1:53535" }]);
  assert.deepEqual(publishedPorts("0.0.0.0:8000-8001->8000-8001/tcp").map(p => p.port), [8000, 8001]);
  assert.deepEqual(publishedPorts("[fe80::1]:9000->9000/tcp"), [{ port: 9000, url: "http://[fe80::1]:9000" }]);
  assert.deepEqual(publishedPorts(""), []);
};

cases["terminal commands split into argv and fail without a terminal"] = assert => {
  assert.deepEqual(splitCommand("flatpak run org.kde.kwi -e"), ["flatpak", "run", "org.kde.kwi", "-e"]);
  assert.deepEqual(splitCommand(` "/opt/my term/bin" --title 'Hafen Logs' -e `), ["/opt/my term/bin", "--title", "Hafen Logs", "-e"]);
  assert.deepEqual(splitCommand(`term ""`), ["term", ""]);
  assert.throws(() => splitCommand("   "), /No terminal/);
  assert.throws(() => splitCommand(`term "open`), /closing/);
  const c = container("abc", "shop");
  assert.deepEqual(logsCommand(c, [], "Ende"), ["sh", "-c", '"$@"; printf "\\n— %s —" "$0"; read -r _', "Ende", "docker", "logs", "--follow", "--tail", "200", "abc"]);
  assert.deepEqual(logsCommand(c, ["--context", "remote"], "Ende").slice(4, 8), ["docker", "--context", "remote", "logs"]);
  assert.deepEqual(shellCommand(c, []).slice(0, 5), ["docker", "exec", "--interactive", "--tty", "abc"]);
  const source = { workingDir: "/srv/shop", configFiles: ["/srv/shop/compose.yaml"] };
  assert.deepEqual(projectLogsCommand("shop", source, [], "Ende").slice(4), ["docker", "compose", "--project-name", "shop", "--project-directory", "/srv/shop", "--file", "/srv/shop/compose.yaml", "logs", "--follow", "--tail", "200"]);
};

cases["Docker errors name their cause"] = assert => {
  assert.equal(describeError(NOT_STARTED, "execvp: No such file").title, "Docker is not installed");
  assert.equal(describeError(1, "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock").title, "No permission on the Docker socket");
  assert.equal(describeError(1, "failed to connect to the docker API at unix:///x.sock; check if the path is correct and if the daemon is running").title, "The Docker daemon is not running");
  assert.equal(describeError(1, "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?").title, "The Docker daemon is not running");
  assert.deepEqual(describeError(1, ""), { title: "Docker is not reachable", detail: "Exit code 1" });
};

cases["docker stats are parsed and totalled against the whole machine"] = assert => {
  assert.equal(parseSize("513.8MiB"), 513.8 * 1024 ** 2);
  assert.equal(parseSize("1.5GB"), 1.5e9);
  assert.equal(parseSize("0B"), 0);
  assert.throws(() => parseSize("lots"), /unknown size/);
  const stats = parseStats('{"id":"a","cpu":"13.17%","mem":"513.8MiB / 60.43GiB"}\n{"id":"b","cpu":"0.00%","mem":"6.801MiB / 60.43GiB"}\n');
  assert.deepEqual(Object.keys(stats), ["a", "b"]);
  assert.equal(stats.a.cpu, 13.17);
  assert.throws(() => parseStats('{"id":"a","cpu":"--","mem":"1MiB / 2GiB"}'), /CPU/);
  const total = statsTotal({ a: { cpu: 150, mem: 1024 ** 3 }, b: { cpu: 50, mem: 1024 ** 3 } }, 8, 16 * 1024 ** 3);
  assert.deepEqual(total, { cpu: 25, mem: 2 * 1024 ** 3, memShare: 12.5 });
  assert.throws(() => statsTotal({}, 0, 1), /unknown/);
  assert.equal(formatBytes(513.8 * 1024 ** 2), "514 MiB");
  assert.equal(formatBytes(1.5 * 1024 ** 3), "1.5 GiB");
  assert.equal(formatPercent(3.14159), "3.1 %");
  assert.equal(formatPercent(42.4), "42 %");
};

cases["release tags are compared as versions"] = assert => {
  assert.equal(isNewer("v0.3.0", "0.2.0"), true);
  assert.equal(isNewer("v0.2.0", "0.2.0"), false);
  assert.equal(isNewer("0.10.0", "0.9.9"), true);
  assert.equal(isNewer("v0.1.9", "0.2.0"), false);
  assert.throws(() => isNewer("latest", "0.2.0"), /version number/);
};

cases["terminals come from desktop entries, with their command option when it is known"] = assert => {
  const entry = (lines) => ["[Desktop Entry]", "Type=Application", ...lines, "[Desktop Action new]", "Exec=ignored", "Name=Ignored"].join("\n");
  const entries = [
    { id: "org.kde.konsole.desktop", content: entry(["Name=Konsole", "Name[de]=Konsole DE", "TryExec=konsole", "Exec=konsole", "Categories=Qt;KDE;System;TerminalEmulator;"]) },
    { id: "org.kde.konsole.desktop", content: entry(["Name=Shadowed", "Exec=other", "Categories=TerminalEmulator;"]) },
    { id: "org.kde.kwi.desktop", content: entry(["Name=Kwi", "Exec=/usr/bin/flatpak run --branch=master --arch=x86_64 --command=kwi org.kde.kwi %U", "Categories=System;TerminalEmulator;"]) },
    { id: "foo.desktop", content: entry(["Name=Foo", "Exec=foo --single", "Categories=TerminalEmulator;", "X-TerminalArgExec=--"]) },
    { id: "bare.desktop", content: entry(["Name=Bare", "Exec=bare", "Categories=TerminalEmulator;", "X-TerminalArgExec="]) },
    { id: "guess.desktop", content: entry(["Name=Guess", "Exec=guess", "Categories=System;TerminalEmulator;"]) },
    { id: "gone.desktop", content: entry(["Name=Gone", "TryExec=gone", "Exec=gone", "Categories=TerminalEmulator;"]) },
    { id: "hidden.desktop", content: entry(["Name=Hidden", "Hidden=true", "Exec=hidden", "Categories=TerminalEmulator;"]) },
    { id: "editor.desktop", content: entry(["Name=Editor", "Exec=edit", "Categories=Utility;"]) },
  ];
  const has = name => ["konsole", "x-terminal-emulator"].includes(name);
  assert.deepEqual(terminalCandidates(entries, has).map(t => [t.label, t.command, t.verified]), [
    ["Konsole", "konsole -e", true],
    ["Kwi", "/usr/bin/flatpak run --branch=master --arch=x86_64 --command=kwi org.kde.kwi -e", true],
    ["Foo", "foo --single --", true],
    ["Bare", "bare", true],
    ["Default terminal (x-terminal-emulator)", "x-terminal-emulator -e", true],
    ["Guess", "guess -e", false],
  ]);
  assert.equal(stripFieldCodes("app %F --x 100%% %i"), "app --x 100%");
  assert.equal(parseDesktopEntry("[Other]\nName=x\n[Desktop Entry]\nName = y").Name, "y");
};

cases["the search keeps matching projects whole and filters containers by every word"] = assert => {
  const groups = groupContainers([container("web-1", "shop"), container("db-1", "shop"), container("web-1", "blog"), container("tool")], { wiki: { workingDir: "/w", configFiles: ["/w/c.yaml"] } });
  const label = p => (p === "blog" ? "Mein Blog" : p);
  const name = c => (c.name === "container-tool" ? "Werkzeug" : c.name);
  const run = q => filterGroups(groups, q, label, name).map(g => [g.project, g.members.map(c => c.id)]);
  assert.deepEqual(run(""), groups.map(g => [g.project, g.members.map(c => c.id)]));
  assert.deepEqual(run("SHOP"), [["shop", ["web-1", "db-1"]]]);
  assert.deepEqual(run("web"), [["blog", ["web-1"]], ["shop", ["web-1"]]]);
  assert.deepEqual(run("shop web"), [["shop", ["web-1"]]]);
  assert.deepEqual(run("mein"), [["blog", ["web-1"]]]);
  assert.deepEqual(run("werkzeug"), [["", ["tool"]]]);
  assert.deepEqual(run("wiki"), [["wiki", []]]);
  assert.deepEqual(run("nichts"), []);
  const filtered = filterGroups(groups, "web", label, name).find(g => g.project === "shop");
  assert.deepEqual(filtered.active.map(c => c.id), ["web-1"]);
};

cases["problems are reported once, when a container gets into them"] = assert => {
  const up = (id, status = "Up 1 hour") => container(id, "shop", status, "running");
  const exited = (id, code) => container(id, "shop", `Exited (${code}) 1 second ago`, "exited");
  assert.equal(exitCode("Exited (139) 2 hours ago"), 139);
  assert.equal(exitCode("Up 1 hour"), null);
  const kinds = (a, b) => problemsBetween(a, b).map(p => [p.container.id, p.kind, p.code]);
  assert.deepEqual(kinds([up("a"), up("b"), up("c")], [exited("a", 1), exited("b", 0), exited("c", 143)]), [["a", "crashed", 1]]);
  assert.deepEqual(kinds([up("a")], [exited("a", 137)]), []);
  assert.deepEqual(kinds([exited("a", 1)], [exited("a", 1)]), []);
  assert.deepEqual(kinds([up("a")], [container("a", "shop", "Restarting (1) 1 second ago", "restarting")]), [["a", "restarting", null]]);
  assert.deepEqual(kinds([up("a")], [container("a", "shop", "Dead", "dead")]), [["a", "dead", null]]);
  assert.deepEqual(kinds([up("a", "Up 1 hour (healthy)")], [up("a", "Up 1 hour (unhealthy)")]), [["a", "unhealthy", null]]);
  assert.deepEqual(kinds([up("a", "Up 1 hour (unhealthy)")], [up("a", "Up 2 hours (unhealthy)")]), []);
  assert.deepEqual(kinds([], [exited("new", 1)]), []);
};

cases["disk usage and the space a prune freed are read from Docker's output"] = assert => {
  const rows = parseDiskUsage('{"Active":"14","Reclaimable":"33.55GB (68%)","Size":"49.28GB","TotalCount":"124","Type":"Images"}\n{"Active":"0","Reclaimable":"48.65GB","Size":"65.14GB","TotalCount":"1056","Type":"Build Cache"}\n');
  assert.deepEqual(rows[0], { type: "Images", total: "124", active: "14", size: "49.28GB", reclaimable: "33.55GB (68%)" });
  assert.equal(rows[1].type, "Build Cache");
  assert.throws(() => parseDiskUsage('{"Type":"Images"}'), /system df/);
  assert.equal(reclaimed("Deleted Containers:\nabc\n\nTotal reclaimed space: 1.597GB\n"), "1.597GB");
  assert.equal(reclaimed("ID\tRECLAIMABLE\nx\ttrue\nTotal:\t48.65GB\n"), "48.65GB");
  assert.equal(reclaimed("nothing"), null);
  assert.equal(Object.values(PRUNE).some(args => args.includes("volume")), false);
};

cases["docker contexts are listed with their endpoint"] = assert => {
  assert.deepEqual(parseContexts('{"Current":true,"Description":"x","DockerEndpoint":"unix:///var/run/docker.sock","Error":"","Name":"default"}\n{"Current":false,"DockerEndpoint":"ssh://box","Error":"","Name":"box"}\n'),
    [{ name: "default", current: true, endpoint: "unix:///var/run/docker.sock", error: "" }, { name: "box", current: false, endpoint: "ssh://box", error: "" }]);
  assert.throws(() => parseContexts('{"Name":"x"}'), /context ls/);
};
