import { formatRemaining } from "./matcher.js";

const params = new URLSearchParams(location.search);
const reason = params.get("reason");
const url = params.get("u");

const title = document.getElementById("title");
const detail = document.getElementById("detail");
const remaining = document.getElementById("remaining");

if (reason === "extensions") {
  title.textContent = "Extension settings are locked";
  detail.textContent = "Extension management is unavailable during a strict Focus session.";
} else if (reason === "status") {
  title.textContent = "Focus Blocker";
} else if (url) {
  try {
    detail.textContent = new URL(url).hostname;
  } catch {
    detail.textContent = url;
  }
}

async function render() {
  const { policy } = await chrome.storage.local.get("policy");
  if (!policy?.active) {
    remaining.textContent = "";
    if (reason === "status") detail.textContent = "No session is running.";
    return;
  }
  remaining.textContent = formatRemaining(policy.estimatedEnd);
  if (reason === "status") detail.textContent = policy.strict ? "Strict session in progress" : "Session in progress";
}

document.getElementById("back").addEventListener("click", () => {
  if (history.length > 1) history.back();
  else window.close();
});
render();
setInterval(render, 1000);
