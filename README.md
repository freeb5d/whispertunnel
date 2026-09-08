# WhisperTunnel

A lightweight TCP-over-WebSocket tunnel written in Go. Traffic is carried
over a standard WSS connection on port 443 with a real TLS certificate,
so it looks like ordinary HTTPS traffic to network inspection.

## How it works

```
[ your app ] --TCP--> [ client :2222 ] --WSS--> [ server :443 ] --TCP--> [ target service ]
```

- **Server** — runs on the exit node. Terminates TLS, serves a normal-
  looking page at `/`, and upgrades a chosen path (e.g. `/assets/app.js`)
  to a WebSocket connection. Data received over that WebSocket is
  forwarded to a local target (e.g. `127.0.0.1:22`).
- **Client** — runs on the entry node. Opens a local TCP listener. Every
  connection accepted there is tunneled over WSS to the server, which
  forwards it to the target service.

Everything ships as a **single binary and a single systemd service**:
the tunnel and the web panel run together in one process.

## Features

- Single static binary, no runtime dependencies
- Config-driven (`config.json`) — one binary, two roles
- Built-in web panel — status, logs, and key rotation from a browser
- Systemd service with auto-restart
- Interactive management CLI (`whispertunnel`) for day-to-day operation
- One-line installer with automatic SSL via Certbot

## Requirements

- Go 1.21+ (only if building from source)
- A domain pointing at the server's IP, with port 80/443 reachable, if
  using automatic Certbot certificates

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/freeb5d/whispertunnel/main/install.sh)
```

The installer asks whether this machine is a **server** or **client**,
generates a config, obtains an SSL certificate (optional, automatic via
Certbot), and installs the systemd service — which also brings up the
web panel on a random port with a randomly generated username and
password, printed once at the end of installation.

## Web panel

A dashboard is built into the same binary and process as the tunnel:
live status, start/stop/restart, logs, config overview, and tunnel-key
rotation, styled as a small dark-themed panel.

The installer prints the panel URL and credentials at the end of setup:

```
==================================================
 Web panel:
   URL:      http://203.0.113.10:41822/
   Username: admin_x7f2q9
   Password: 3fJ8pQ1zW0mR6tYaC4bN9dLk
==================================================
```

Since the panel and tunnel share one process, using Stop or Restart
from the panel restarts the whole service (panel included) — this is
expected.

If you lose the credentials, get them again (or generate new ones):

```bash
whispertunnel      # then choose "Show web panel URL/credentials"
                    # or "Reset web panel credentials"
```

Put the panel behind a reverse proxy with its own TLS if you want to
access it over HTTPS instead of plain HTTP.

## Managing the service

After install, run:

```bash
whispertunnel
```

for an interactive menu:

```
==================================================
              WhisperTunnel Manager
==================================================
Service status: * running
Role: server
--------------------------------------------------
 1) Start
 2) Stop
 3) Restart
 4) Full status
 5) View live logs
 6) Show config
 7) Edit config
 8) Change tunnel key
 9) Reconfigure (role/domain/port...)
10) Enable start on boot
11) Disable start on boot
12) Update to latest release
13) Uninstall
14) Get/renew SSL certificate (Certbot)
15) Show web panel URL/credentials
16) Reset web panel credentials
 0) Exit
==================================================
Choose an option:
```

The header always shows the live service status (running/stopped) and
the configured role (server/client). Enter a number to run that action.

Non-interactive shortcuts also work:

```bash
whispertunnel start
whispertunnel stop
whispertunnel restart
whispertunnel status
whispertunnel logs
whispertunnel uninstall
```

## Build from source

```bash
git clone https://github.com/freeb5d/whispertunnel
cd whispertunnel
go mod tidy
go build -o whispertunnel .
```

## Manual configuration

### Tunnel — Server (`config.json`)

```json
{
  "role": "server",
  "domain": "example.com",
  "ws_path": "/assets/app.js",
  "target": "127.0.0.1:22",
  "listen_port": 443,
  "tunnel_key": "change-me-secret",
  "cert_path": "/etc/letsencrypt/live/example.com/fullchain.pem",
  "key_path": "/etc/letsencrypt/live/example.com/privkey.pem"
}
```

### Tunnel — Client (`config.json`)

```json
{
  "role": "client",
  "remote_url": "wss://example.com/assets/app.js",
  "local_addr": "127.0.0.1:2222",
  "tunnel_key": "change-me-secret"
}
```

### Panel (`panel.json`, optional)

```json
{
  "listen_port": 41822,
  "username": "admin_x7f2q9",
  "password": "change-me"
}
```

Run with both:

```bash
./whispertunnel -config config.json -panel-config panel.json
```

If `panel.json` is missing, the tunnel runs without the panel.

## Staying unremarkable

- Use a real certificate, not self-signed.
- Give the WebSocket path an innocuous name, not `/tunnel` or `/ws`.
- Serve a plausible page at `/` for anyone who visits the domain directly.
- Keep `tunnel_key` private; requests without it get a plain 404.

## Uninstall

```bash
whispertunnel uninstall
```

## License

MIT
