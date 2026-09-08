// WhisperTunnel — a TCP-over-WebSocket tunnel designed to blend in with
// ordinary HTTPS web traffic.
//
// Usage:
//   whispertunnel -config config.json
//
// The "role" field inside config.json determines whether this process
// runs as a server (terminates TLS, upgrades to WS, forwards to a local
// target) or a client (dials the server over WSS, exposes a local TCP
// listener).
package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/gorilla/websocket"
)

// ---------- Config ----------

type Config struct {
	Role string `json:"role"` // "server" or "client"

	// Server fields
	Domain      string `json:"domain,omitempty"`
	WSPath      string `json:"ws_path,omitempty"`
	Target      string `json:"target,omitempty"`
	ListenPort  int    `json:"listen_port,omitempty"`
	CertPath    string `json:"cert_path,omitempty"`
	KeyPath     string `json:"key_path,omitempty"`

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
		if r.Header.Get("X-Tunnel-Key") != cfg.TunnelKey {
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

		pipeWSToTCP(conn, target)
	})

	port := cfg.ListenPort
	if port == 0 {
		port = 443
	}

	srv := &http.Server{
		Addr:    ":" + itoa(port),
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Printf("[server] listening on :%d (ws path: %s)\n", port, wsPath)
	log.Fatal(srv.ListenAndServeTLS(cfg.CertPath, cfg.KeyPath))
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
	log.Printf("[client] local listener on %s -> %s\n", cfg.LocalAddr, cfg.RemoteURL)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println("accept error:", err)
			continue
		}
		go handleClientConn(cfg, conn)
	}
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

	pipeTCPToWS(local, ws)
}

// ---------- Shared pipe helpers ----------

// pipeWSToTCP relays data between an already-upgraded WS connection and a TCP conn (server side).
func pipeWSToTCP(ws *websocket.Conn, tcp net.Conn) {
	errc := make(chan error, 2)

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

// pipeTCPToWS relays data between a local TCP conn and a WS connection (client side).
func pipeTCPToWS(tcp net.Conn, ws *websocket.Conn) {
	errc := make(chan error, 2)

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

	<-errc
}

// itoa avoids importing strconv just for one call site's readability preference.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// ---------- main ----------

func main() {
	configPath := flag.String("config", "config.json", "path to config.json")
	flag.Parse()

	cfg := loadConfig(*configPath)

	if cfg.TunnelKey == "" {
		log.Fatal("config missing tunnel_key")
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
