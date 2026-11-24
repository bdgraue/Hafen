// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

export const REFRESH_MS = 5000;
const FIELDS = ["id", "name", "image", "status", "state", "ports", "project", "workingDir", "configFiles"];
export const DOCKER_ARGS = [
  "ps", "--all", "--format",
  '{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"status":{{json .Status}},"state":{{json .State}},"ports":{{json .Ports}},'
    + '"project":{{json (.Label "com.docker.compose.project")}},"workingDir":{{json (.Label "com.docker.compose.project.working_dir")}},'
    + '"configFiles":{{json (.Label "com.docker.compose.project.config_files")}}}',
];

export function parseContainers(stdout) {
  return stdout.split(/\r?\n/).filter(line => line.trim()).map(line => {
    const row = JSON.parse(line);
    for (const key of FIELDS) {
      if (typeof row[key] !== "string") throw new Error("Ungültige Docker-Antwort");
    }
    return row;
  }).sort((a, b) => a.project.localeCompare(b.project) || a.name.localeCompare(b.name));
}

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
    .map(([project, members]) => ({ project, members, running: members.filter(isRunning) }));
}

export function health(status) {
  if (/\(unhealthy\)/i.test(status)) return "unhealthy";
  if (/\(health: starting\)/i.test(status)) return "starting";
  return "ok";
}

const HEALTH_RANK = { ok: 0, starting: 1, unhealthy: 2 };

export function groupHealth(members) {
  return members.filter(isRunning).map(c => health(c.status)).reduce((worst, h) => (HEALTH_RANK[h] > HEALTH_RANK[worst] ? h : worst), "ok");
}

export function statusColor(container, t) {
  if (!isRunning(container)) return t.stopped;
  const h = health(container.status);
  return h === "unhealthy" ? t.blocked : h === "starting" ? t.working : t.done;
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
  const text = status.replace(/^(Up|Exited \(-?\d+\))\s+/i, "").replace(/\s+ago$/i, "").replace(/\s*\(.*\)\s*$/, "");
  let m = text.match(/^(\d+)\s+(second|minute|hour|day|week|month|year)s?$/i);
  if (m) return `${m[1]}${UNITS[m[2].toLowerCase()]}`;
  m = text.match(/^About an? (second|minute|hour|day|week|month|year)$/i);
  if (m) return `~1${UNITS[m[1].toLowerCase()]}`;
  m = text.match(/^Less than a (second|minute)$/i);
  if (m) return `<1${UNITS[m[1].toLowerCase()]}`;
  return text;
}

const firstLine = text => (text.trim().split("\n")[0] || "unbekannter Fehler").slice(0, 200);

const VERBS = {
  stop: { done: "gestoppt", failed: "Stoppen" },
  start: { done: "gestartet", failed: "Starten" },
  restart: { done: "neu gestartet", failed: "Neustarten" },
};

// A notification for actions that went wrong; null when every container did what was asked.
export function actionSummary(action, label, results) {
  const verb = VERBS[action];
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
