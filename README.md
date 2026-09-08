# WhisperTunnel

A lightweight TCP-over-WebSocket tunnel written in Go, designed to blend
in with ordinary HTTPS web traffic (WSS handshake on port 443, browser-like
headers, a real TLS certificate).

## How it works

- **Server** (runs on your remote/exit box): terminates TLS, serves a
  normal-looking page at `/`, and upgrades a chosen path (e.g.
  `/assets/app.js`) to a WebSocket connection. Traffic received over that
  WebSocket is forwarded to a local target (e.g. `127.0.0.1:22`).
- **Client** (runs on your local/entry box): opens a local TCP listener.
  Every connection accepted there is tunneled over a WSS connection to the
  server, which forwards it to the target service.

```
[ your app ] --TCP--> [ client :2222 ] --WSS--> [ server :443 ] --TCP--> [ target service ]
```

## Requirements

- Go 1.21+
- A real domain with a valid TLS certificate (e.g. via Let's Encrypt) on
  the server side — this matters far more than any other setting for
  staying unremarkable to network inspection.

## Build from source

```bash
git clone https://github.com/freeb5d/whispertunnel
cd whispertunnel
go mod tidy
go build -o whispertunnel .
```

## Quick install (prebuilt binary)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/freeb5d/whispertunnel/main/install.sh)
```

The installer asks whether this machine is a **server** or **client**,
generates a config, and installs a systemd service. It also installs a
management command — after install, just run:

```bash
whispertunnel
```

to get an interactive menu (start/stop/restart, view logs, view or edit
config, rotate the tunnel key, reconfigure, update, uninstall) — similar
to the menu of familiar panel installers like `x-ui`.

Non-interactive shortcuts also work:

```bash
whispertunnel start
whispertunnel stop
whispertunnel restart
whispertunnel status
whispertunnel logs
whispertunnel uninstall
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

## Notes on blending in

- Use a real certificate, not self-signed.
- Give the WebSocket path an innocuous name, not `/tunnel` or `/ws`.
- Serve a plausible page at `/` for anyone who visits the domain directly.
- Keep `tunnel_key` private; requests without it get a plain 404.

## Uninstall

```bash
bash install.sh uninstall
```

## License

MIT
