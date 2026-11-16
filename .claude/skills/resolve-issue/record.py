#!/usr/bin/env python3
"""Record the plugin against a synthetic account with Shellwright.

    record.py <script.json> <out-dir> <label>

Plays the same steps every time, so a "before" and an "after" recording
differ only by the code. Writes <out-dir>/<label>.gif (trimmed with
trim-gif.py), <out-dir>/<label>-raw.gif and one PNG per screenshot step.

The script file:

    {
      "fixture": "dist/test/fixtures/synthetic.json",
      "cols": 110, "rows": 30, "theme": "one-dark",
      "steps": [
        {"until": "sync", "timeout": 30000},     # wait for text on screen
        {"wait": 3000},                          # let the replay finish
        {"keys": "j", "wait": 600},
        {"keys": "\\r", "wait": 1500},
        {"screenshot": "chat"}
      ]
    }

"keys" are sent as typed; use \\r for Enter and \\u001b for Escape. Without a
Shellwright server on SHELLWRIGHT_URL (default http://localhost:7498/mcp) one
is started for the run and stopped after. Standard library only.
"""
import json, os, shutil, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
URL = os.environ.get("SHELLWRIGHT_URL", "http://localhost:7498/mcp")
SHELLWRIGHT = "@dwmkerr/shellwright@0.1.10"


class Client:
    def __init__(self, url):
        self.url, self.session, self.n = url, None, 0

    def _post(self, body):
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if self.session:
            req.add_header("mcp-session-id", self.session)
        with urllib.request.urlopen(req, timeout=180) as r:
            self.session = self.session or r.headers.get("mcp-session-id")
            text = r.read().decode()
        # Streamable HTTP answers either as JSON or as server-sent events.
        data = [l[5:].strip() for l in text.splitlines() if l.startswith("data:")]
        text = data[-1] if data else text
        return json.loads(text) if text.strip() else {}

    def connect(self):
        self._post({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "record.py", "version": "1"}}})
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def call(self, tool, **args):
        self.n += 1
        res = self._post({"jsonrpc": "2.0", "id": self.n, "method": "tools/call",
                          "params": {"name": tool, "arguments": args}})
        if "error" in res:
            raise RuntimeError(f"{tool}: {res['error']}")
        text = "".join(c.get("text", "") for c in res.get("result", {}).get("content", []))
        try:
            return json.loads(text)
        except ValueError:
            return text


def reachable(client):
    try:
        client.connect()
        return True
    except OSError:
        return False


def start_server(root, cols, rows):
    log = open(os.path.join(root, "scratch", "shellwright", "server.log"), "a")
    proc = subprocess.Popen(
        ["npx", "-y", SHELLWRIGHT, "--http", "--font-size", "14", "--cols", str(cols), "--rows", str(rows),
         "--temp-dir", os.path.join(root, "scratch", "shellwright", "tmp")],
        cwd=root, stdout=log, stderr=log)
    client = Client(URL)
    for _ in range(90):
        if reachable(client):
            return proc, client
        time.sleep(1)
    proc.terminate()
    sys.exit("shellwright did not start; see scratch/shellwright/server.log")


def wait_for(client, sid, text, timeout_ms):
    """Poll the screen until text shows, so slow starts never cut a recording short."""
    deadline = time.time() + timeout_ms / 1000
    while time.time() < deadline:
        screen = client.call("shell_read", session_id=sid)
        if text in (screen if isinstance(screen, str) else json.dumps(screen)):
            return
        time.sleep(0.25)
    raise RuntimeError(f"{text!r} did not appear within {timeout_ms} ms")


def download(url, path):
    urllib.request.urlretrieve(url, path)


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    script_path, out_dir, label = sys.argv[1:]
    script = json.load(open(script_path))
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    os.makedirs(os.path.join(root, "scratch", "shellwright"), exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)
    cols, rows = script.get("cols", 110), script.get("rows", 30)
    fixture = os.path.join(root, script.get("fixture", "dist/test/fixtures/synthetic.json"))

    server = None
    client = Client(URL)
    if not reachable(client):
        server, client = start_server(root, cols, rows)
    subprocess.run(["make", "-C", root, "build"], check=True, stdout=subprocess.DEVNULL)

    sid = client.call("shell_start", command="bash", args=["--noprofile", "--norc"],
                      cols=cols, rows=rows, theme=script.get("theme", "one-dark"))["shell_session_id"]
    try:
        client.call("shell_send", session_id=sid, input=f"cd {root} && clear\n", delay_ms=300)
        # Shellwright renders every frame on its event loop; at 10 fps a full
        # Neovim screen starves it and every call slows to tens of seconds.
        client.call("shell_record_start", session_id=sid, fps=script.get("fps", 4))
        # Shellwright does not answer terminal queries yet (dwmkerr/shellwright#87).
        # COLORTERM stops Neovim asking about truecolor; NVIM_TEST hides the
        # warning about the unanswered background query.
        client.call("shell_send", session_id=sid,
                    input=f"COLORTERM=truecolor NVIM_TEST=1 make -s demo FIXTURE={fixture}\n", delay_ms=200)
        for step in script["steps"]:
            if "keys" in step:
                client.call("shell_send", session_id=sid, input=step["keys"], delay_ms=step.get("wait", 500))
            elif "screenshot" in step:
                shot = client.call("shell_screenshot", session_id=sid, name=f"{label}-{step['screenshot']}")
                download(shot["download_url"], os.path.join(out_dir, f"{label}-{step['screenshot']}.png"))
            elif "until" in step:
                wait_for(client, sid, step["until"], step.get("timeout", 30000))
                time.sleep(step.get("wait", 0) / 1000)
            elif "wait" in step:
                time.sleep(step["wait"] / 1000)
        rec = client.call("shell_record_stop", session_id=sid, name=label)
        raw = os.path.join(out_dir, f"{label}-raw.gif")
        download(rec["download_url"], raw)
        client.call("shell_send", session_id=sid, input="\x1b:qa!\r", delay_ms=800)
    finally:
        client.call("shell_stop", session_id=sid)
        if server:
            server.terminate()
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "trim-gif.py"), raw,
                    os.path.join(out_dir, f"{label}.gif")], check=True)


if __name__ == "__main__":
    main()
