// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

// Runs inside Qt's JavaScript engine as well as under Node for the tests: no object spread, no Node APIs.

export const REFRESH_MS = 5000;
// Hidden in the tray only the warning overlay needs fresh data; showing the window reads at once.
export const HIDDEN_REFRESH_MS = 30000;
// While `docker events` reports every change, polling only keeps the uptimes current and covers a lost event.
export const WATCHED_REFRESH_MS = 30000;
export const WATCHED_HIDDEN_REFRESH_MS = 120000;
// A `compose up` fires dozens of events within a second; they become one refresh.
export const EVENT_DEBOUNCE_MS = 300;
// `docker stats --no-stream` takes about two seconds, so it gets its own, slower timer.
export const STATS_REFRESH_MS = 10000;
// Reading the list or the stats must not wait forever on a hanging daemon. Actions get no limit:
// `docker stop` has its own grace period and `compose up` may pull images for minutes.
export const READ_TIMEOUT_MS = 20000;
export const NO_TIMEOUT = 0;

const FIELDS = ["id", "name", "image", "status", "state", "ports", "project", "workingDir", "configFiles"];
export const DOCKER_ARGS = [
  "ps", "--all", "--format",
  '{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"status":{{json .Status}},"state":{{json .State}},"ports":{{json .Ports}},'
    + '"project":{{json (.Label "com.docker.compose.project")}},"workingDir":{{json (.Label "com.docker.compose.project.working_dir")}},'
    + '"configFiles":{{json (.Label "com.docker.compose.project.config_files")}}}',
];
export const STATS_ARGS = ["stats", "--no-stream", "--format", '{"id":{{json .ID}},"cpu":{{json .CPUPerc}},"mem":{{json .MemUsage}}}'];

export function parseContainers(stdout) {
  return stdout.split(/\r?\n/).filter(line => line.trim()).map(line => {
    const row = JSON.parse(line);
    for (const key of FIELDS) {
      if (typeof row[key] !== "string") throw new Error("Ungültige Docker-Antwort");
    }
    return row;
  }).sort((a, b) => a.project.localeCompare(b.project) || a.name.localeCompare(b.name));
}

// Docker's own state machine decides what can be offered: a paused container cannot be started, only unpaused,
// and Docker refuses to remove anything that is running, paused or restarting.
const STATES = {
  running: { active: true, start: false, unpause: false, stop: true, restart: true, remove: false, shell: true },
  paused: { active: true, start: false, unpause: true, stop: true, restart: true, remove: false, shell: false },
  restarting: { active: true, start: false, unpause: false, stop: true, restart: true, remove: false, shell: false },
  created: { active: false, start: true, unpause: false, stop: false, restart: false, remove: true, shell: false },
  exited: { active: false, start: true, unpause: false, stop: false, restart: false, remove: true, shell: false },
  dead: { active: false, start: false, unpause: false, stop: false, restart: false, remove: true, shell: false },
  removing: { active: false, start: false, unpause: false, stop: false, restart: false, remove: false, shell: false },
};
const NOTHING = STATES.removing;

// An unknown future state offers nothing rather than a command Docker may refuse.
export const actionsFor = container => STATES[container.state] ?? NOTHING;
export const isActive = container => actionsFor(container).active;
export const isRunning = container => container.state === "running";

// What `docker compose up` needs to bring a project back after `docker compose down` removed its containers.
export function composeSources(containers) {
  const sources = {};
  for (const c of containers) {
    if (!c.project || !c.workingDir || !c.configFiles) continue;
    sources[c.project] = { workingDir: c.workingDir, configFiles: c.configFiles.split(",").filter(Boolean) };
  }
  return sources;
}

export function composeUpArgs(project, source) {
  if (!source?.workingDir || !source.configFiles?.length) throw new Error(`Für ${project} ist kein Compose-Verzeichnis gespeichert.`);
  return ["compose", "--project-name", project, "--project-directory", source.workingDir,
    ...source.configFiles.flatMap(file => ["--file", file]), "up", "--detach"];
}

// Remembered projects without any container left still get a group, so they can be started again.
export function groupContainers(containers, remembered = {}) {
  const groups = new Map();
  for (const container of containers) {
    if (!groups.has(container.project)) groups.set(container.project, []);
    groups.get(container.project).push(container);
  }
  for (const project of Object.keys(remembered)) {
    if (!groups.has(project)) groups.set(project, []);
  }
  return [...groups]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([project, members]) => ({ project, members, active: members.filter(isActive) }));
}

// A Compose project counts as active while any of its containers is. Standalone containers are no unit,
// so they split: the active ones go to the active section, the others to the inactive one.
export function splitSections(groups) {
  const active = [], inactive = [];
  for (const group of groups) {
    if (group.project) {
      (group.active.length ? active : inactive).push(Object.assign({}, group, { key: group.project }));
      continue;
    }
    const idle = group.members.filter(c => !isActive(c));
    if (group.active.length) active.push({ project: "", key: ":standalone-active", members: group.active, active: group.active });
    if (idle.length) inactive.push({ project: "", key: ":standalone-inactive", members: idle, active: [] });
  }
  return { active, inactive };
}

export function health(status) {
  if (/\(unhealthy\)/i.test(status)) return "unhealthy";
  if (/\(health: starting\)/i.test(status)) return "starting";
  return "ok";
}

// Worth a look: a failing healthcheck, a restart loop or a dead container.
export function condition(container) {
  if (container.state === "restarting" || container.state === "dead") return "unhealthy";
  if (container.state === "paused") return "starting";
  return isRunning(container) ? health(container.status) : "ok";
}

const CONDITION_RANK = { ok: 0, starting: 1, unhealthy: 2 };

export function groupHealth(members) {
  return members.map(condition).reduce((worst, h) => (CONDITION_RANK[h] > CONDITION_RANK[worst] ? h : worst), "ok");
}

export function statusColor(container, t) {
  const c = condition(container);
  if (c === "unhealthy") return t.blocked;
  if (c === "starting") return t.working;
  return isRunning(container) ? t.done : t.stopped;
}

export function containerTooltip(container) {
  return [container.name, container.image, container.status, `Ports: ${container.ports || "keine"}`].join("\n");
}

// Inside its project's group, "shop-web-1" reads as "web-1".
export function shortName(container) {
  const prefix = `${container.project}-`;
  return container.project && container.name.startsWith(prefix) && container.name.length > prefix.length
    ? container.name.slice(prefix.length)
    : container.name;
}

// "Up 7 hours" -> "7h", "Exited (0) 3 days ago" -> "3d". Docker's units: second(s), minute(s), hour(s), day(s), week(s),
// month(s), year(s); "About an hour" -> "~1h", "Less than a second" -> "<1s". Anything else stays as Docker wrote it.
const UNITS = { second: "s", minute: "m", hour: "h", day: "d", week: "w", month: "mo", year: "y" };
export function uptime(status) {
  const text = status.replace(/^(Up|(Exited|Restarting) \(-?\d+\))\s+/i, "").replace(/\s+ago$/i, "").replace(/\s*\(.*\)\s*$/, "");
  let m = text.match(/^(\d+)\s+(second|minute|hour|day|week|month|year)s?$/i);
  if (m) return `${m[1]}${UNITS[m[2].toLowerCase()]}`;
  m = text.match(/^About an? (second|minute|hour|day|week|month|year)$/i);
  if (m) return `~1${UNITS[m[1].toLowerCase()]}`;
  m = text.match(/^Less than a (second|minute)$/i);
  if (m) return `<1${UNITS[m[1].toLowerCase()]}`;
  return text;
}

// "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 1025/tcp" -> one URL per published TCP port on the host.
// Unpublished ("1025/tcp") and UDP ports have nothing a browser could open.
export function publishedPorts(ports) {
  const seen = new Map();
  for (const part of ports.split(",")) {
    const m = part.trim().match(/^(.*):(\d+)(?:-(\d+))?->\d+(?:-\d+)?\/tcp$/);
    if (!m) continue;
    const ip = m[1].replace(/^\[|\]$/g, "");
    const host = ip === "0.0.0.0" || ip === "::" || ip === "" ? "127.0.0.1" : ip.includes(":") ? `[${ip}]` : ip;
    const first = Number(m[2]), last = Number(m[3] ?? m[2]);
    for (let port = first; port <= last; port++) {
      if (!seen.has(port)) seen.set(port, `http://${host}:${port}`);
    }
  }
  return [...seen].sort(([a], [b]) => a - b).map(([port, url]) => ({ port, url }));
}

// Splits a terminal command such as `flatpak run org.kde.kwi -e` into argv. Quotes group words; nothing else is special.
export function splitCommand(command) {
  const words = [];
  let word = null, quote = null;
  for (const ch of command) {
    if (quote) {
      if (ch === quote) quote = null;
      else word += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      if (word === null) word = "";
    } else if (/\s/.test(ch)) {
      if (word !== null) words.push(word);
      word = null;
    } else {
      word = (word ?? "") + ch;
    }
  }
  if (quote) throw new Error(`Im Terminal-Befehl fehlt ein schließendes ${quote}.`);
  if (word !== null) words.push(word);
  if (!words.length) throw new Error("Kein Terminal eingestellt. In den Einstellungen einen Terminal-Befehl angeben.");
  return words;
}

// The terminal closes when its command ends; without the pause the logs of a stopped container would flash past.
export function logsCommand(container) {
  return ["sh", "-c", 'docker logs --follow --tail 200 -- "$1"; printf "\\n— Ende der Logs. Enter schließt das Fenster. —"; read -r _', "sh", container.id];
}

export function shellCommand(container) {
  return ["docker", "exec", "--interactive", "--tty", container.id, "sh", "-c", "[ -x /bin/bash ] && exec bash || exec sh"];
}

// Docker.run reports this exit code when the docker program could not be started at all.
export const NOT_STARTED = -2;

// Docker 29 says "permission denied while trying to connect to the docker API" and "failed to connect to the docker API …
// check … if the daemon is running"; older versions say "Cannot connect to the Docker daemon".
export function describeError(code, stderr) {
  const text = stderr.trim();
  if (code === NOT_STARTED) {
    return { title: "Docker ist nicht installiert", detail: `Das Programm docker wurde nicht gefunden. ${text}` };
  }
  if (/permission denied/i.test(text)) {
    return { title: "Keine Rechte am Docker-Socket", detail: `Den Benutzer in die Gruppe docker aufnehmen und neu anmelden. ${text}` };
  }
  if (/failed to connect to the docker API|Cannot connect to the Docker daemon|Is the docker daemon running/i.test(text)) {
    return { title: "Docker-Dienst läuft nicht", detail: text };
  }
  return { title: "Docker nicht erreichbar", detail: text || `Exit ${code}` };
}

const SIZE_UNITS = { B: 1, kB: 1e3, KB: 1e3, MB: 1e6, GB: 1e9, TB: 1e12, KiB: 1024, MiB: 1024 ** 2, GiB: 1024 ** 3, TiB: 1024 ** 4 };

export function parseSize(text) {
  const m = text.trim().match(/^([\d.]+)\s*([kKMGT]?i?B)$/);
  if (!m || !(m[2] in SIZE_UNITS)) throw new Error(`Unbekannte Größe von Docker: ${text}`);
  return Number(m[1]) * SIZE_UNITS[m[2]];
}

// id -> { cpu: percent of one core, mem: bytes }. Docker's CPUPerc is relative to a single core.
export function parseStats(stdout) {
  const stats = {};
  for (const line of stdout.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const row = JSON.parse(line);
    if (typeof row.id !== "string" || typeof row.cpu !== "string" || typeof row.mem !== "string") throw new Error("Ungültige Antwort von docker stats");
    const cpu = Number(row.cpu.replace("%", ""));
    if (!Number.isFinite(cpu)) throw new Error(`Ungültiger CPU-Wert von docker stats: ${row.cpu}`);
    stats[row.id] = { cpu, mem: parseSize(row.mem.split("/")[0]) };
  }
  return stats;
}

// The total reads as "how much of this machine": CPU against every core, memory against all of it.
export function statsTotal(stats, cores, memTotal) {
  if (!(cores > 0) || !(memTotal > 0)) throw new Error("Kerne und Arbeitsspeicher des Rechners sind unbekannt.");
  let cpu = 0, mem = 0;
  for (const id in stats) {
    cpu += stats[id].cpu;
    mem += stats[id].mem;
  }
  return { cpu: cpu / cores, mem, memShare: (mem / memTotal) * 100 };
}

export function formatBytes(bytes) {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let i = 0;
  while (bytes >= 1024 && i < units.length - 1) {
    bytes /= 1024;
    i++;
  }
  return `${bytes >= 100 || i === 0 ? Math.round(bytes) : bytes.toFixed(1)} ${units[i]}`;
}

export const formatPercent = value => `${value >= 10 ? Math.round(value) : value.toFixed(1)} %`;

const firstLine = text => (text.trim().split("\n")[0] || "unbekannter Fehler").slice(0, 200);

export const ACTIONS = {
  start: { args: id => ["start", id], done: "gestartet", failed: "Starten" },
  stop: { args: id => ["stop", id], done: "gestoppt", failed: "Stoppen" },
  restart: { args: id => ["restart", id], done: "neu gestartet", failed: "Neustarten" },
  unpause: { args: id => ["unpause", id], done: "fortgesetzt", failed: "Fortsetzen" },
  // Plain `docker rm`: no --force for anything still running, no --volumes, so every volume survives.
  remove: { args: id => ["rm", id], done: "gelöscht", failed: "Löschen" },
};

export function actionArgs(action, id) {
  const known = ACTIONS[action];
  if (!known) throw new Error(`Unbekannte Aktion: ${action}`);
  return known.args(id);
}

// A notification for actions that went wrong; null when every container did what was asked.
export function actionSummary(action, label, results) {
  const verb = ACTIONS[action];
  if (!verb) throw new Error(`Unbekannte Aktion: ${action}`);
  const failed = results.filter(r => r.error);
  if (!failed.length) return null;
  const done = results.length - failed.length;
  return {
    title: done ? `${label}: ${done} von ${results.length} Containern ${verb.done}` : `${label}: ${verb.failed} fehlgeschlagen`,
    body: failed.map(r => `${r.name}: ${firstLine(r.error)}`).join("\n"),
    level: done ? "warning" : "error",
  };
}

// "v0.2.0" or "0.2.0" against "0.1.3": true when the release is newer than what runs.
export function isNewer(release, current) {
  const parse = v => {
    const m = String(v).trim().match(/^v?(\d+)\.(\d+)\.(\d+)$/);
    if (!m) throw new Error(`Ungültige Versionsnummer: ${v}`);
    return m.slice(1).map(Number);
  };
  const a = parse(release), b = parse(current);
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] > b[i];
  }
  return false;
}

// Terminals whose option for running a command was checked against their --help.
const VERIFIED_EXEC_ARG = { "org.kde.konsole.desktop": "-e", "org.kde.kwi.desktop": "-e" };

// Keys of the [Desktop Entry] group; actions and other groups are skipped, localized keys ("Name[de]") too.
export function parseDesktopEntry(text) {
  const entry = {};
  let inMain = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[")) {
      inMain = line === "[Desktop Entry]";
      continue;
    }
    const eq = line.indexOf("=");
    if (!inMain || eq < 0) continue;
    const key = line.slice(0, eq).trim();
    if (!(key in entry)) entry[key] = line.slice(eq + 1).trim();
  }
  return entry;
}

// "%f", "%U" and the other field codes stand for files or URLs Hafen never passes; "%%" is a literal percent sign.
export const stripFieldCodes = exec => exec.replace(/(^|\s)%[fFuUdDnNickvm](?=\s|$)/g, "").replace(/%%/g, "%").trim();

// entries: [{ id, content }] in XDG order, the first file of an id wins. has(program) tells whether a program is on PATH.
// The proposed XDG terminal spec lets a terminal declare its option in X-TerminalArgExec; without it the option is only
// known for terminals listed above, and for the rest "-e" is a guess, the same default xdg-terminal-exec assumes.
export function terminalCandidates(entries, has) {
  const seen = new Set(), found = [];
  for (const { id, content } of entries) {
    if (seen.has(id)) continue;
    seen.add(id);
    const e = parseDesktopEntry(content);
    if (e.Type !== "Application" || e.Hidden === "true" || !e.Exec || !e.Name) continue;
    if (!(e.Categories ?? "").split(";").includes("TerminalEmulator")) continue;
    if (e.TryExec && !has(e.TryExec)) continue;
    const declared = e["X-TerminalArgExec"] ?? e.TerminalArgExec;
    const arg = declared ?? VERIFIED_EXEC_ARG[id] ?? "-e";
    const exec = stripFieldCodes(e.Exec);
    found.push({ id, label: e.Name, command: arg ? `${exec} ${arg}` : exec, verified: declared !== undefined || id in VERIFIED_EXEC_ARG });
  }
  // Debian policy 11.8.3 requires x-terminal-emulator to run "-e command args…" like execvp.
  if (has("x-terminal-emulator")) found.push({ id: "x-terminal-emulator", label: "Standard-Terminal (x-terminal-emulator)", command: "x-terminal-emulator -e", verified: true });
  // xdg-terminal-exec takes the command directly and opens the terminal chosen in xdg-terminals.list.
  if (has("xdg-terminal-exec")) found.push({ id: "xdg-terminal-exec", label: "Standard-Terminal (xdg-terminal-exec)", command: "xdg-terminal-exec", verified: true });
  return found.sort((a, b) => Number(b.verified) - Number(a.verified));
}
