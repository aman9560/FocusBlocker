// Focus Blocker service worker.
//
// The native host (focus-nmh) is the only source of rules. The extension applies them as declarativeNetRequest
// dynamic rules, which Chrome enforces in the network stack and keeps across browser restarts. When the host is
// unreachable the last rules stay in force until the session's estimated end, so losing the host never unblocks early.

import { isBlocked, isExtensionsPage } from "./matcher.js";

const HOST = "com.focusblocker.nmh";
const VERSION = chrome.runtime.getManifest().version;
const BLOCK_PAGE = chrome.runtime.getURL("blocked.html");
const HEARTBEAT_MS = 15_000;
// Leeway after the estimated end before stale rules are dropped while the host is unreachable.
const EXPIRY_GRACE_MS = 60_000;

let port = null;
let heartbeatTimer = null;
let reconnectDelay = 1_000;
let policy = null;

async function currentPolicy() {
  if (!policy) policy = (await chrome.storage.local.get("policy")).policy ?? null;
  return policy;
}

// MARK: Native host connection

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    port = null;
    setStatus("host-missing");
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError?.message ?? "disconnected";
    console.warn("Focus host disconnected:", reason);
    port = null;
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
    setStatus(reason.includes("not found") || reason.includes("forbidden") ? "host-missing" : "host-down");
    scheduleReconnect();
  });
  reconnectDelay = 1_000;
  sendHeartbeat("hello");
  heartbeatTimer = setInterval(() => sendHeartbeat("heartbeat"), HEARTBEAT_MS);
}

function scheduleReconnect() {
  setTimeout(connect, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 60_000);
}

async function sendHeartbeat(type) {
  if (!port) return;
  const [incognitoAllowed, rules, p] = await Promise.all([
    chrome.extension.isAllowedIncognitoAccess(),
    chrome.declarativeNetRequest.getDynamicRules(),
    currentPolicy(),
  ]);
  try {
    port?.postMessage({ type, version: VERSION, incognitoAllowed, rulesRevision: p?.revision ?? "", ruleCount: rules.length });
  } catch (error) {
    console.warn("heartbeat failed", error);
  }
}

async function onHostMessage(message) {
  if (message.type === "policy") {
    await applyPolicy(message);
  } else if (message.type === "error") {
    // Keep the existing rules: an engine error must not lift a block.
    console.error("Focus host error:", message.message);
    setStatus("error");
  }
}

// MARK: Applying policy

async function applyPolicy(message) {
  const rules = message.active ? message.rules : [];
  const existing = await chrome.declarativeNetRequest.getDynamicRules();
  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: existing.map((r) => r.id), addRules: rules });

  policy = {
    active: message.active,
    strict: message.strict,
    revision: message.revision,
    estimatedEnd: message.estimatedEnd,
    domains: message.domains,
    exceptions: message.exceptions,
    receivedAt: Date.now(),
  };
  await chrome.storage.local.set({ policy });
  await chrome.alarms.clear("expiry");
  if (policy.active && policy.estimatedEnd) {
    chrome.alarms.create("expiry", { when: policy.estimatedEnd + EXPIRY_GRACE_MS });
  }
  setStatus(port ? "connected" : "host-down");
  if (policy.active) await sweepTabs();
  sendHeartbeat("heartbeat");
}

/** Redirects open tabs that the new rules block; declarativeNetRequest only acts on new requests. */
async function sweepTabs() {
  const tabs = await chrome.tabs.query({});
  await Promise.all(tabs.map((tab) => checkTab(tab.id, tab.url)));
}

async function checkTab(tabId, url) {
  const p = await currentPolicy();
  if (!url || !p?.active) return;
  if (isBlocked(p, url)) {
    await redirect(tabId, `${BLOCK_PAGE}?u=${encodeURIComponent(url)}`);
  } else if (p.strict && isExtensionsPage(url)) {
    // Friction, not enforcement: the toolbar menu can still remove the extension, which the agent detects.
    await redirect(tabId, `${BLOCK_PAGE}?reason=extensions`);
  }
}

async function redirect(tabId, target) {
  try {
    await chrome.tabs.update(tabId, { url: target });
  } catch {
    await chrome.tabs.remove(tabId).catch(() => {});
  }
}

async function setStatus(status) {
  const p = await currentPolicy();
  const text = status === "connected" ? (p?.active ? "ON" : "") : status === "error" ? "!" : p?.active ? "ON" : "OFF";
  const color = status === "connected" ? "#2f7d32" : p?.active ? "#b26a00" : "#9e9e9e";
  await chrome.action.setBadgeText({ text });
  await chrome.action.setBadgeBackgroundColor({ color });
  await chrome.action.setTitle({ title: `Focus Blocker: ${p?.active ? "session active" : "no session"} (${status})` });
}

// MARK: Events

// Catches in-page navigations (for example YouTube moving to /shorts) that never issue a main-frame request.
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.url) checkTab(tabId, change.url);
});
chrome.tabs.onCreated.addListener((tab) => checkTab(tab.id, tab.pendingUrl || tab.url));

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name === "keepalive") {
    connect();
  } else if (alarm.name === "expiry") {
    const p = await currentPolicy();
    // Only drop rules on our own when the host can't tell us; otherwise it will send the inactive policy.
    if (!port && p?.active && Date.now() >= p.estimatedEnd + EXPIRY_GRACE_MS) {
      await applyPolicy({ active: false, strict: false, revision: "expired", estimatedEnd: null, domains: [], exceptions: [], rules: [] });
    }
  }
});

chrome.action.onClicked.addListener(() => chrome.tabs.create({ url: `${BLOCK_PAGE}?reason=status` }));
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create("keepalive", { periodInMinutes: 0.5 });
connect();
