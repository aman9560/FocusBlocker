// Run with: node --test Tests/extension/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isBlocked, isExtensionsPage, formatRemaining, parseRule } from "../../Extension/matcher.js";

const fixture = JSON.parse(readFileSync(new URL("../fixtures/url-cases.json", import.meta.url)));
const policy = { active: true, domains: fixture.domains, exceptions: fixture.exceptions };

test("matches the shared URL cases exactly like FocusCore", () => {
  for (const { url, blocked } of fixture.cases) {
    assert.equal(isBlocked(policy, url), blocked, url);
  }
});

test("nothing is blocked without an active policy", () => {
  assert.equal(isBlocked(null, "https://reddit.com"), false);
  assert.equal(isBlocked({ ...policy, active: false }, "https://reddit.com"), false);
  assert.equal(isBlocked(policy, "not a url"), false);
});

test("recognizes extension management pages", () => {
  for (const url of ["chrome://extensions", "chrome://extensions/?id=abc", "CHROME://EXTENSIONS/shortcuts", "brave://extensions"]) {
    assert.ok(isExtensionsPage(url), url);
  }
  for (const url of ["chrome://settings", "https://chrome.google.com/webstore", "chrome://extensionsx"]) {
    assert.equal(isExtensionsPage(url), false, url);
  }
  assert.equal(isExtensionsPage(undefined), false);
});

test("parses rules and formats remaining time", () => {
  assert.deepEqual(parseRule("youtube.com/shorts"), { host: "youtube.com", path: "/shorts" });
  assert.deepEqual(parseRule("x.com"), { host: "x.com", path: null });
  assert.equal(formatRemaining(1_000 + 3_725_000, 1_000), "1h 02m");
  assert.equal(formatRemaining(1_000 + 65_000, 1_000), "1m 05s");
  assert.equal(formatRemaining(0, 5_000), "");
});

test("manifest pins the key and requests only what blocking needs", () => {
  const manifest = JSON.parse(readFileSync(new URL("../../Extension/manifest.json", import.meta.url)));
  assert.equal(manifest.manifest_version, 3);
  assert.ok(manifest.key.length > 300);
  assert.deepEqual([...manifest.permissions].sort(), ["alarms", "declarativeNetRequest", "nativeMessaging", "storage", "tabs"]);
  assert.equal(manifest.incognito, "spanning");
  assert.deepEqual(manifest.web_accessible_resources[0].resources, ["blocked.html"]);
});

test("an all-websites rule blocks everything except the exceptions", () => {
  const allowlist = { active: true, domains: ["*", "google.com"], exceptions: ["docs.google.com", "chat.openai.com"] };
  assert.equal(isBlocked(allowlist, "https://example.com/"), true);
  assert.equal(isBlocked(allowlist, "https://google.com/search?q=1"), true);
  assert.equal(isBlocked(allowlist, "https://docs.google.com/document/d/1"), false);
  assert.equal(isBlocked(allowlist, "https://chat.openai.com/"), false);
  assert.equal(isBlocked(allowlist, "chrome://settings"), false);
  assert.equal(isBlocked(allowlist, "file:///Users/me/notes.html"), false);
});
