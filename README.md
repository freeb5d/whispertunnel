<div align="center">

# WhisperTunnel

**A TCP‑over‑WebSocket tunnel that hides in plain sight as ordinary HTTPS traffic.**

[![Go Version](https://img.shields.io/badge/Go-1.21%2B-00ADD8?logo=go&logoColor=white)](https://go.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#license)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)](#requirements)

</div>

---

WhisperTunnel wraps a plain TCP connection inside a standard **WSS**
(WebSocket‑over‑TLS) session on port 443, using a real certificate. To
anyone inspecting the traffic, it looks exactly like a normal HTTPS
visit to a web page — because part of it is one.

Everything ships as a **single static binary** and a **single systemd
service**: the tunnel and its web management panel run together in one
process, with a guided installer that gets you from zero to running in
under a minute.

## Table of contents

- [How it works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Web panel](#web-panel)
- [Managing the service](#managing-the-service)
- [Build from source](#build-from-source)
- [Manual configuration](#manual-configuration)
- [Staying unremarkable](#staying-unremarkable)
- [Uninstall](#uninstall)
- [License](#license)

## How it works

```
┌──────────┐   TCP    ┌──────────────┐   WSS (443)   ┌──────────────┐   TCP    ┌─────────────────┐
│ your app │ ───────▶ │ client :2222 │ ────────────▶ │ server :443  │ ───────▶ │ target service  │
└──────────┘          └──────────────┘                └──────────────┘          └─────────────────┘
```

| Role | Runs on | Does |
|---|---|---|
| **Server** | the exit node | Terminates TLS, serves a normal‑looking page at `/`, and upgrades one chosen path (e.g. `/assets/app.js`) to a WebSocket. Traffic received there is forwarded to a local target (e.g. `127.0.0.1:22`). |
| **Client** | the entry node | Opens a local TCP listener. Every connection accepted there is tunneled over WSS to the server, which forwards it on to the target service. |

## Features

- 🧱 Single static binary, no runtime dependencies
- ⚙️ Config‑driven (`config.json`) — one binary, two roles
- 📊 Built‑in web panel — live status, logs, and key rotation from a browser
- 🔁 Systemd service with auto‑restart and graceful shutdown
- 🖥️ Interactive management CLI (`whispertunnel`) for day‑to‑day operation
- 🔐 One‑line installer with automatic SSL via Certbot
- 🛡️ Rate‑limited panel login, constant‑time key checks, WebSocket keepalive

## Requirements

- Go 1.21+ (only if building from source)
- A domain pointing at the server's IP, with port 80/443 reachable, if
  using automatic Certbot certificates

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/freeb5d/whispertunnel/main/install.sh)
```

The installer walks you through everything:

1. Asks whether this machine is a **server** or **client** and writes `config.json`.
2. For a server, optionally obtains an SSL certificate automatically via Certbot.
3. Asks how the **web panel** should be exposed — localhost‑only (recommended) or all interfaces.
4. Installs and starts the systemd service, then prints the panel URL and credentials once.

## Web panel

<div align="center">
<em>Status · Start / Stop / Restart · Live logs · Config overview · Tunnel‑key rotation</em>
</div>

A small dark‑themed dashboard is built into the same binary and
process as the tunnel — no separate install, no extra service.

During install you choose how it's exposed:

| Option | Behavior |
|---|---|
| **Localhost only** (recommended) | Binds to `127.0.0.1`; not reachable from outside the box at all. Reach it over SSH: `ssh -L 8080:127.0.0.1:<port> user@your-server`, then open `http://127.0.0.1:8080/`. |
| **All interfaces** | Binds to `0.0.0.0`; reachable directly at `http://<server-ip>:<port>/`, protected by the panel login (rate‑limited). Put a reverse proxy with TLS in front if you want HTTPS. |

The installer prints access instructions and credentials once, at the end of setup:

```
==================================================
 Web panel:
   Localhost only — from your machine, run:
   ssh -L 8080:127.0.0.1:41822 <user>@203.0.113.10
   then open: http://127.0.0.1:8080/
   Username: admin_x7f2q9
   Password: 3fJ8pQ1zW0mR6tYaC4bN9dLk
==================================================
```

> **Note:** the panel and tunnel share one process, so using Stop or
> Restart from the panel restarts the whole service — that's expected.

Lost the credentials? Get them again, or roll new ones:

```bash
whispertunnel      # then choose "Show web panel URL/credentials"
                    # or "Reset web panel credentials"
```

## Managing the service

```bash
whispertunnel
```

opens an interactive menu:

```
==================================================
              WhisperTunnel Manager
==================================================
Service status: ● running
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

The header always shows the live service status and configured role.
Non‑interactive shortcuts also work, for scripting:

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

<details>
<summary><strong>Tunnel — Server (<code>config.json</code>)</strong></summary>

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

</details>

<details>
<summary><strong>Tunnel — Client (<code>config.json</code>)</strong></summary>

```json
{
  "role": "client",
  "remote_url": "wss://example.com/assets/app.js",
  "local_addr": "127.0.0.1:2222",
  "tunnel_key": "change-me-secret"
}
```

</details>

<details>
<summary><strong>Panel — <code>panel.json</code> (optional)</strong></summary>

```json
{
  "listen_addr": "127.0.0.1",
  "listen_port": 41822,
  "username": "admin_x7f2q9",
  "password": "change-me"
}
```

`listen_addr` is optional and defaults to `0.0.0.0` (all interfaces) if
omitted. Set it to `127.0.0.1` to keep the panel reachable only from
the server itself (e.g. over an SSH‑forwarded port).

</details>

Run with both:

```bash
./whispertunnel -config config.json -panel-config panel.json
```

If `panel.json` is missing, the tunnel runs without the panel.

## Staying unremarkable

- ✅ Use a real certificate, not self‑signed.
- ✅ Give the WebSocket path an innocuous name, not `/tunnel` or `/ws`.
- ✅ Serve a plausible page at `/` for anyone who visits the domain directly.
- ✅ Keep `tunnel_key` private; requests without it get a plain 404.

## Uninstall

```bash
whispertunnel uninstall
```

## License

[MIT](LICENSE)
