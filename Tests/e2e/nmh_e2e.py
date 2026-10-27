"""End-to-end check of the real focus-nmh binary, speaking Chrome's framing over pipes.

Usage: python3 -I Tests/e2e/nmh_e2e.py .build  (uses a temporary state folder; touches nothing else)
"""
import json, os, struct, subprocess, sys, tempfile, time, select

build = os.path.abspath(sys.argv[1])
state = tempfile.mkdtemp(prefix="focus-e2e-")
env = dict(os.environ, FOCUS_STATE_DIR=state)

def ctl(*args, stdin=None):
    r = subprocess.run([f"{build}/focusctl", *args], env=env, input=stdin, capture_output=True, text=True)
    assert r.returncode == 0, (args, r.stdout, r.stderr)
    return r.stdout

def send(proc, msg):
    body = json.dumps(msg).encode()
    proc.stdin.write(struct.pack("<I", len(body)) + body)
    proc.stdin.flush()

def recv(proc, timeout):
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    if not ready:
        return None
    header = proc.stdout.read(4)
    (n,) = struct.unpack("<I", header)
    return json.loads(proc.stdout.read(n))

ctl("blocklist", "create", "Social", "--domain", "reddit.com", "--domain", "youtube.com/shorts")
host = subprocess.Popen([f"{build}/focus-nmh", "chrome-extension://mchnpkbnifalondddkmcbplnlebaebmd/"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
send(host, {"type": "hello", "version": "0.1.0", "incognitoAllowed": False, "rulesRevision": "", "ruleCount": 0})
first = recv(host, 5)
assert first["type"] == "policy" and first["active"] is False, first
print("hello -> inactive policy ✓")

t0 = time.time()
ctl("start", "--blocklist", "Social", "--minutes", "30", "--lock", "timer")
pushed = recv(host, 5)
assert pushed and pushed["active"] and pushed["strict"] and len(pushed["rules"]) == 4, pushed
print(f"session started in focusctl -> pushed to host within {time.time() - t0:.1f}s with {len(pushed['rules'])} rules ✓")

send(host, {"type": "heartbeat", "version": "0.1.0", "incognitoAllowed": False,
            "rulesRevision": pushed["revision"], "ruleCount": 4})
assert recv(host, 1) is None
beat = json.load(open(f"{state}/heartbeat-chrome.json"))
assert beat["ruleCount"] == 4 and beat["extensionOrigin"].startswith("chrome-extension://mchnp"), beat
print("heartbeat recorded ✓")
print(ctl("chrome", "status").strip())

host.stdin.close()
assert host.wait(5) == 0
print("host exits cleanly when Chrome closes the port ✓")
print(ctl("audit", "--verify").strip())
