// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

import test from "node:test";
import assert from "node:assert/strict";
import {
  parseContainers, groupContainers, groupHealth, statusColor, containerTooltip, shortName, uptime, actionSummary,
  composeSources, composeUpArgs,
} from "../src/model.mjs";

const container = (id, project = "", status = "Up 2 hours", state = "running") => ({
  id, name: project ? `${project}-${id}` : `container-${id}`, image: "example:latest", status, state,
  ports: "127.0.0.1:8080->80/tcp", project,
  workingDir: project ? `/srv/${project}` : "", configFiles: project ? `/srv/${project}/compose.yaml,/srv/${project}/compose.override.yaml` : "",
});
const ndjson = containers => containers.map(row => JSON.stringify(row)).join("\n");
const colors = { blocked: "red", working: "amber", done: "green", stopped: "grey" };

test("parses Docker NDJSON, sorts and groups Compose projects and standalone containers", () => {
  const rows = parseContainers(`\n${ndjson([container("z", "shop"), container("x"), container("a", "shop", "Exited (0) 3 days ago", "exited")])}\r\n`);
  assert.deepEqual(rows.map(row => row.id), ["x", "a", "z"]);
  const groups = groupContainers(rows);
  assert.deepEqual(groups.map(g => [g.project, g.members.length, g.running.length]), [["", 1, 1], ["shop", 2, 1]]);
  assert.deepEqual(parseContainers("\n"), []);
  assert.throws(() => parseContainers("not json"));
  assert.throws(() => parseContainers('{"id":"incomplete"}'), /Docker/);
});

test("remembered projects without containers keep an empty group", () => {
  const groups = groupContainers([container("a", "shop")], { blog: { workingDir: "/srv/blog", configFiles: ["/srv/blog/compose.yaml"] } });
  assert.deepEqual(groups.map(g => [g.project, g.members.length]), [["blog", 0], ["shop", 1]]);
});

test("compose sources come from the labels and build a compose up command", () => {
  const sources = composeSources([container("a", "shop"), container("x")]);
  assert.deepEqual(sources, { shop: { workingDir: "/srv/shop", configFiles: ["/srv/shop/compose.yaml", "/srv/shop/compose.override.yaml"] } });
  assert.deepEqual(composeUpArgs("shop", sources.shop), [
    "compose", "--project-name", "shop", "--project-directory", "/srv/shop",
    "--file", "/srv/shop/compose.yaml", "--file", "/srv/shop/compose.override.yaml", "up", "--detach",
  ]);
  assert.throws(() => composeUpArgs("blog", undefined), /blog/);
  assert.throws(() => composeUpArgs("blog", { workingDir: "/srv/blog", configFiles: [] }), /blog/);
});

test("health colors, compact names, uptime and tooltip", () => {
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
});

test("action summary stays quiet on success and names partial and total failures", () => {
  const ok = { name: "shop-a", error: null };
  const bad = { name: "shop-b", error: "Error response from daemon: boom\nmore" };
  assert.equal(actionSummary("stop", "shop", [ok]), null);
  assert.deepEqual(actionSummary("stop", "shop", [ok, bad]), { title: "shop: 1 von 2 Containern gestoppt", body: "shop-b: Error response from daemon: boom", level: "warning" });
  assert.equal(actionSummary("start", "shop", [bad]).title, "shop: Starten fehlgeschlagen");
  assert.equal(actionSummary("restart", "shop", [bad]).level, "error");
  assert.throws(() => actionSummary("pause", "shop", [bad]), /pause/);
});
