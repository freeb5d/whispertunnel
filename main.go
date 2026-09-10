// WhisperTunnel — a TCP-over-WebSocket tunnel designed to blend in with
// ordinary HTTPS web traffic, with an optional built-in web panel for
// management.
//
// Usage:
//   whispertunnel -config config.json [-panel-config panel.json]
//
// The "role" field inside config.json determines whether the tunnel
// runs as a server (terminates TLS, upgrades to WS, forwards to a
// local target) or a client (dials the server over WSS, exposes a
// local TCP listener). If -panel-config points to an existing file,
// the web panel also starts, in the same process.
package main

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

const version = "2.0.0"

// ---------- Config ----------

type Config struct {
	Role string `json:"role"` // "server" or "client"

	// Server fields
	Domain     string `json:"domain,omitempty"`
	WSPath     string `json:"ws_path,omitempty"`
	Target     string `json:"target,omitempty"`
	ListenPort int    `json:"listen_port,omitempty"`
	CertPath   string `json:"cert_path,omitempty"`
	KeyPath    string `json:"key_path,omitempty"`

	// Client fields
	RemoteURL string `json:"remote_url,omitempty"`
	LocalAddr string `json:"local_addr,omitempty"`

	// Shared
	TunnelKey string `json:"tunnel_key"`
}

func loadConfig(path string) *Config {
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("cannot open config: %v", err)
	}
	defer f.Close()

	var cfg Config
	if err := json.NewDecoder(f).Decode(&cfg); err != nil {
		log.Fatalf("invalid config: %v", err)
	}
	return &cfg
}

// ---------- Server ----------

var upgrader = websocket.Upgrader{
	ReadBufferSize:  16 * 1024,
	WriteBufferSize: 16 * 1024,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

// constEqual compares two strings in constant time, without leaking their
// length difference through timing (unlike a bare `==`, which would let a
// remote attacker distinguish key lengths/prefixes by measuring response time).
func constEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func runServer(cfg *Config) {
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("<html><body><h1>It works</h1></body></html>"))
	})

	wsPath := cfg.WSPath
	if wsPath == "" {
		wsPath = "/assets/app.js"
	}

	mux.HandleFunc(wsPath, func(w http.ResponseWriter, r *http.Request) {
		if !constEqual(r.Header.Get("X-Tunnel-Key"), cfg.TunnelKey) {
			http.NotFound(w, r)
			return
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Println("upgrade error:", err)
			return
		}
		defer conn.Close()

		target, err := net.DialTimeout("tcp", cfg.Target, 5*time.Second)
		if err != nil {
			log.Println("dial target error:", err)
			return
		}
		defer target.Close()

		pipe(conn, target)
	})

	port := cfg.ListenPort
	if port == 0 {
		port = 443
	}

	srv := &http.Server{
		Addr:              ":" + strconv.Itoa(port),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	go func() {
		log.Printf("[tunnel] server listening on :%d (ws path: %s)\n", port, wsPath)
		if err := srv.ListenAndServeTLS(cfg.CertPath, cfg.KeyPath); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	waitForShutdown(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	})
}

// waitForShutdown blocks until SIGINT/SIGTERM, then runs shutdown and returns.
func waitForShutdown(shutdown func()) {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Println("[tunnel] shutting down...")
	shutdown()
}

// ---------- Client ----------

func runClient(cfg *Config) {
	if cfg.LocalAddr == "" {
		log.Fatal("client config missing local_addr")
	}
	if cfg.RemoteURL == "" {
		log.Fatal("client config missing remote_url")
	}

	ln, err := net.Listen("tcp", cfg.LocalAddr)
	if err != nil {
		log.Fatalf("listen error: %v", err)
	}
	log.Printf("[tunnel] client listener on %s -> %s\n", cfg.LocalAddr, cfg.RemoteURL)

	var wg sync.WaitGroup
	go waitForShutdown(func() {
		_ = ln.Close()
	})

	for {
		conn, err := ln.Accept()
		if err != nil {
			if isClosedErr(err) {
				break
			}
			log.Println("accept error:", err)
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			handleClientConn(cfg, conn)
		}()
	}
	wg.Wait()
}

func isClosedErr(err error) bool {
	return errors.Is(err, net.ErrClosed)
}

func handleClientConn(cfg *Config, local net.Conn) {
	defer local.Close()

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
		TLSClientConfig:  &tls.Config{},
	}

	header := http.Header{}
	header.Set("X-Tunnel-Key", cfg.TunnelKey)
	header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36")

	ws, resp, err := dialer.Dial(cfg.RemoteURL, header)
	if err != nil {
		status := ""
		if resp != nil {
			status = resp.Status
		}
		log.Println("dial error:", err, status)
		return
	}
	defer ws.Close()

	pipe(ws, local)
}

// ---------- Shared pipe helper ----------

const (
	maxMessageSize = 1 << 20 // 1 MiB per WS message; bounds memory per connection
	pingInterval   = 30 * time.Second
	pongWait       = 60 * time.Second
)

// pipe relays bytes bidirectionally between a WebSocket and a TCP connection
// until either side closes or errors. It also sends periodic pings so idle
// connections aren't silently dropped by intermediate proxies/load balancers.
func pipe(ws *websocket.Conn, tcp net.Conn) {
	errc := make(chan error, 2)

	ws.SetReadLimit(maxMessageSize)
	_ = ws.SetReadDeadline(time.Now().Add(pongWait))
	ws.SetPongHandler(func(string) error {
		return ws.SetReadDeadline(time.Now().Add(pongWait))
	})

	done := make(chan struct{})
	defer close(done)

	go func() {
		ticker := time.NewTicker(pingInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := ws.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
					return
				}
			case <-done:
				return
			}
		}
	}()

	go func() {
		for {
			_, msg, err := ws.ReadMessage()
			if err != nil {
				errc <- err
				return
			}
			if _, err := tcp.Write(msg); err != nil {
				errc <- err
				return
			}
		}
	}()

	go func() {
		buf := make([]byte, 16*1024)
		for {
			n, err := tcp.Read(buf)
			if err != nil {
				errc <- err
				return
			}
			if err := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); err != nil {
				errc <- err
				return
			}
		}
	}()

	<-errc
}

// ---------- main ----------

func main() {
	configPath := flag.String("config", "config.json", "path to config.json")
	panelConfigPath := flag.String("panel-config", "panel.json", "path to panel.json (panel starts only if this file exists)")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		log.Printf("whispertunnel v%s\n", version)
		os.Exit(0)
	}

	cfg := loadConfig(*configPath)
	if cfg.TunnelKey == "" {
		log.Fatal("config missing tunnel_key")
	}

	// Start the web panel in the background if a panel config is present.
	if _, err := os.Stat(*panelConfigPath); err == nil {
		go runPanel(*panelConfigPath, *configPath)
	}

	switch cfg.Role {
	case "server":
		runServer(cfg)
	case "client":
		runClient(cfg)
	default:
		log.Fatalf("unknown role %q (expected \"server\" or \"client\")", cfg.Role)
	}
}
