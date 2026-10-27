// URL matching that mirrors FocusCore's DomainRule and the compiled declarativeNetRequest rules.
// Kept free of chrome.* APIs so it can be tested with Node.

/** Splits an already-normalized rule such as "youtube.com/shorts" into host and path prefix. */
export function parseRule(raw) {
  const slash = raw.indexOf("/");
  return slash < 0 ? { host: raw, path: null } : { host: raw.slice(0, slash), path: raw.slice(slash) };
}

/** A rule covers its host and every subdomain; a path prefix only matches whole segments. */
export function ruleMatches(rule, host, path) {
  // "*" blocks every website; exceptions then act as an allowlist.
  if (rule.host === "*") return true;
  const h = host.toLowerCase().replace(/\.$/, "");
  if (h !== rule.host && !h.endsWith("." + rule.host)) return false;
  if (!rule.path) return true;
  const p = path.toLowerCase();
  return p === rule.path || p.startsWith(rule.path + "/");
}

/** True when the active policy blocks `url`. Exceptions win, as allow rules do in Chrome. */
export function isBlocked(policy, url) {
  if (!policy || !policy.active) return false;
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
  const matches = (raw) => ruleMatches(parseRule(raw), parsed.hostname, parsed.pathname);
  return policy.domains.some(matches) && !policy.exceptions.some(matches);
}

/** Chrome's extension management pages, where the extension itself could be switched off. */
export function isExtensionsPage(url) {
  return /^(chrome|edge|brave|vivaldi|opera):\/\/(extensions|apps)\b/i.test(url || "");
}

/** Remaining time for display, from the engine's estimated end (milliseconds since 1970). */
export function formatRemaining(estimatedEnd, now = Date.now()) {
  if (!estimatedEnd) return "";
  const total = Math.max(0, Math.ceil((estimatedEnd - now) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0 ? `${h}h ${String(m).padStart(2, "0")}m` : `${m}m ${String(s).padStart(2, "0")}s`;
}
