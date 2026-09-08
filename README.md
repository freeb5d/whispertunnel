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

## Features

- Single static binary, no runtime dependencies
- Config-driven (`config.json`) — one binary, two roles
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
Certbot), and installs a systemd service.

## Managing the service

After install, run:

```bash
whispertunnel
```

for an interactive menu: start/stop/restart, view logs, view or edit the
config, rotate the tunnel key, reconfigure, renew the SSL certificate,
update, or uninstall.

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

### Server (`config.json`)

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

### Client (`config.json`)

```json
{
  "role": "client",
  "remote_url": "wss://example.com/assets/app.js",
  "local_addr": "127.0.0.1:2222",
  "tunnel_key": "change-me-secret"
}
```

Run either with:

```bash
./whispertunnel -config config.json
```

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
