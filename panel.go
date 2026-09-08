// WhisperTunnel Panel — a small web dashboard for managing the
// whispertunnel service: status, start/stop/restart, logs, config
// view, and tunnel-key rotation. Runs in-process alongside the tunnel.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
)

type PanelConfig struct {
	ListenPort int    `json:"listen_port"`
	Username   string `json:"username"`
	Password   string `json:"password"`
}

var panelCfg PanelConfig
var panelTunnelConfigPath string

func loadPanelConfig(path string) {
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("cannot open panel config: %v", err)
	}
	defer f.Close()
	if err := json.NewDecoder(f).Decode(&panelCfg); err != nil {
		log.Fatalf("invalid panel config: %v", err)
	}
}

func readTunnelConfigRaw() (map[string]interface{}, error) {
	b, err := os.ReadFile(panelTunnelConfigPath)
	if err != nil {
		return nil, err
	}
	var m map[string]interface{}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func basicAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		userOK := ok && subtle.ConstantTimeCompare([]byte(u), []byte(panelCfg.Username)) == 1
		passOK := ok && subtle.ConstantTimeCompare([]byte(p), []byte(panelCfg.Password)) == 1
		if !userOK || !passOK {
			w.Header().Set("WWW-Authenticate", `Basic realm="WhisperTunnel Panel"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func runSystemctl(args ...string) (string, error) {
	cmd := exec.Command("systemctl", args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func serviceIsActive() bool {
	_, err := runSystemctl("is-active", "--quiet", "whispertunnel")
	return err == nil
}

// ---------- HTTP handlers ----------

const dashboardTmpl = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>WhisperTunnel Panel</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --bg: #0f1115;
    --panel: #171a21;
    --panel-alt: #1e2229;
    --border: #262b34;
    --text: #e6e8eb;
    --muted: #8b93a1;
    --accent: #6f7bff;
    --accent-dark: #5563e8;
    --green: #3ddc84;
    --red: #ff5c72;
    --radius: 10px;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  .topbar {
    display: flex; align-items: center; justify-content: space-between;
    padding: 18px 28px; border-bottom: 1px solid var(--border);
    background: var(--panel);
  }
  .topbar h1 { font-size: 18px; margin: 0; letter-spacing: 0.3px; }
  .topbar .brand { display:flex; align-items:center; gap:10px; }
  .dot { width: 10px; height: 10px; border-radius: 50%; display:inline-block; }
  .dot.on { background: var(--green); box-shadow: 0 0 8px var(--green); }
  .dot.off { background: var(--red); box-shadow: 0 0 8px var(--red); }
  .container { max-width: 980px; margin: 32px auto; padding: 0 20px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 18px; }
  .card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px;
  }
  .card h2 { font-size: 14px; text-transform: uppercase; letter-spacing: 0.6px; color: var(--muted); margin: 0 0 14px; }
  .kv { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid var(--border); font-size: 14px; }
  .kv:last-child { border-bottom: none; }
  .kv span:first-child { color: var(--muted); }
  .status-badge { padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; }
  .status-badge.on { background: rgba(61,220,132,0.12); color: var(--green); }
  .status-badge.off { background: rgba(255,92,114,0.12); color: var(--red); }
  .btnrow { display: flex; gap: 10px; margin-top: 16px; flex-wrap: wrap; }
  button {
    background: var(--accent);
    color: #fff; border: none; border-radius: 8px;
    padding: 9px 16px; font-size: 13px; font-weight: 600; cursor: pointer;
    transition: background 0.15s;
  }
  button:hover { background: var(--accent-dark); }
  button.secondary { background: var(--panel-alt); color: var(--text); border: 1px solid var(--border); }
  button.secondary:hover { background: #262b34; }
  button.danger { background: var(--red); }
  button.danger:hover { background: #e14a5f; }
  pre#logbox {
    background: #0b0d11; border: 1px solid var(--border); border-radius: 8px;
    padding: 14px; height: 320px; overflow-y: auto; font-size: 12.5px;
    line-height: 1.5; color: #c7ccd4; white-space: pre-wrap; word-break: break-all;
  }
  .toast {
    position: fixed; bottom: 24px; right: 24px; background: var(--panel-alt);
    border: 1px solid var(--border); border-radius: 8px; padding: 12px 18px;
    font-size: 13px; opacity: 0; transform: translateY(10px);
    transition: all 0.25s;
  }
  .toast.show { opacity: 1; transform: translateY(0); }
  .fullwidth { grid-column: 1 / -1; }
  code.key {
    background: var(--panel-alt); padding: 2px 8px; border-radius: 6px;
    font-size: 12.5px; color: var(--accent);
  }
</style>
</head>
<body>
  <div class="topbar">
    <div class="brand">
      <span class="dot {{if .Running}}on{{else}}off{{end}}" id="statusdot"></span>
      <h1>WhisperTunnel</h1>
    </div>
    <div style="color:var(--muted); font-size:13px;">role: {{.Role}}</div>
  </div>

  <div class="container">
    <div class="grid">
      <div class="card">
        <h2>Service</h2>
        <div class="kv"><span>Status</span><span id="statusbadge" class="status-badge {{if .Running}}on{{else}}off{{end}}">{{if .Running}}running{{else}}stopped{{end}}</span></div>
        <div class="kv"><span>Role</span><span>{{.Role}}</span></div>
        <div class="btnrow">
          <button onclick="doAction('start')">Start</button>
          <button class="secondary" onclick="doAction('restart')">Restart</button>
          <button class="danger" onclick="doAction('stop')">Stop</button>
        </div>
      </div>

      <div class="card">
        <h2>Config</h2>
        {{range $k, $v := .Config}}
        <div class="kv"><span>{{$k}}</span><span>{{$v}}</span></div>
        {{end}}
        <div class="btnrow">
          <button class="secondary" onclick="rotateKey()">Rotate tunnel key</button>
        </div>
      </div>

      <div class="card fullwidth">
        <h2>Live logs</h2>
        <pre id="logbox">loading...</pre>
        <div class="btnrow">
          <button class="secondary" onclick="loadLogs()">Refresh</button>
        </div>
      </div>
    </div>
  </div>

  <div class="toast" id="toast"></div>

<script>
function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 2200);
}

async function doAction(action) {
  const res = await fetch('/api/' + action, { method: 'POST' });
  const data = await res.json();
  toast(data.message || 'done');
  refreshStatus();
}

async function refreshStatus() {
  const res = await fetch('/api/status');
  const data = await res.json();
  const dot = document.getElementById('statusdot');
  const badge = document.getElementById('statusbadge');
  dot.className = 'dot ' + (data.running ? 'on' : 'off');
  badge.className = 'status-badge ' + (data.running ? 'on' : 'off');
  badge.textContent = data.running ? 'running' : 'stopped';
}

async function rotateKey() {
  if (!confirm('Generate a new tunnel key? The service will restart and you must update the other side.')) return;
  const res = await fetch('/api/rotate-key', { method: 'POST' });
  const data = await res.json();
  toast(data.message || 'rotated');
  setTimeout(() => location.reload(), 800);
}

async function loadLogs() {
  const res = await fetch('/api/logs');
  const text = await res.text();
  document.getElementById('logbox').textContent = text;
  const box = document.getElementById('logbox');
  box.scrollTop = box.scrollHeight;
}

loadLogs();
setInterval(refreshStatus, 5000);
setInterval(loadLogs, 15000);
</script>
</body>
</html>`

type dashboardData struct {
	Running bool
	Role    string
	Config  map[string]string
}

func handleDashboard(w http.ResponseWriter, r *http.Request) {
	cfg, _ := readTunnelConfigRaw()
	role := "unknown"
	display := map[string]string{}
	if cfg != nil {
		if v, ok := cfg["role"].(string); ok {
			role = v
		}
		for _, k := range []string{"domain", "ws_path", "target", "listen_port", "remote_url", "local_addr"} {
			if v, ok := cfg[k]; ok {
				display[k] = fmt.Sprintf("%v", v)
			}
		}
	}

	tmpl := template.Must(template.New("dash").Parse(dashboardTmpl))
	data := dashboardData{
		Running: serviceIsActive(),
		Role:    role,
		Config:  display,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = tmpl.Execute(w, data)
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]interface{}{"running": serviceIsActive()})
}

func handleAction(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		out, err := runSystemctl(action, "whispertunnel")
		if err != nil {
			writeJSON(w, map[string]interface{}{"ok": false, "message": strings.TrimSpace(out + " " + err.Error())})
			return
		}
		writeJSON(w, map[string]interface{}{"ok": true, "message": "service " + action + "ed"})
	}
}

func handleLogs(w http.ResponseWriter, r *http.Request) {
	cmd := exec.Command("journalctl", "-u", "whispertunnel", "-n", "200", "--no-pager")
	out, err := cmd.CombinedOutput()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if err != nil {
		w.Write([]byte("could not read logs: " + err.Error() + "\n" + string(out)))
		return
	}
	w.Write(out)
}

func handleRotateKey(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	b, err := os.ReadFile(panelTunnelConfigPath)
	if err != nil {
		writeJSON(w, map[string]interface{}{"ok": false, "message": "cannot read config: " + err.Error()})
		return
	}
	newKey := randomString(32)
	content := string(b)
	// naive JSON field replace, keeps formatting simple
	content = replaceJSONField(content, "tunnel_key", newKey)
	if err := os.WriteFile(panelTunnelConfigPath, []byte(content), 0600); err != nil {
		writeJSON(w, map[string]interface{}{"ok": false, "message": "cannot write config: " + err.Error()})
		return
	}
	runSystemctl("restart", "whispertunnel")
	writeJSON(w, map[string]interface{}{"ok": true, "message": "tunnel key rotated"})
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

// runPanel starts the web panel and blocks; intended to be launched with
// `go runPanel(...)` from the tunnel's main().
func runPanel(panelConfigPath, tunnelConfigPath string) {
	panelTunnelConfigPath = tunnelConfigPath
	loadPanelConfig(panelConfigPath)

	mux := http.NewServeMux()
	mux.HandleFunc("/", basicAuth(handleDashboard))
	mux.HandleFunc("/api/status", basicAuth(handleStatus))
	mux.HandleFunc("/api/start", basicAuth(handleAction("start")))
	mux.HandleFunc("/api/stop", basicAuth(handleAction("stop")))
	mux.HandleFunc("/api/restart", basicAuth(handleAction("restart")))
	mux.HandleFunc("/api/logs", basicAuth(handleLogs))
	mux.HandleFunc("/api/rotate-key", basicAuth(handleRotateKey))

	addr := fmt.Sprintf("0.0.0.0:%d", panelCfg.ListenPort)
	log.Printf("[panel] listening on %s\n", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("[panel] error: %v\n", err)
	}
}
