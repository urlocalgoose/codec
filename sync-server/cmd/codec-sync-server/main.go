package main

import (
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"codec-sync-server/internal/server"
)

func main() {
	addr := flag.String("addr", ":8787", "HTTP listen address")
	dataDir := flag.String("data", "./codec-sync-data", "folder for SQLite state and media blobs")
	webDir := flag.String("web", defaultWebDir(), "folder containing the built Codec web app")
	authToken := flag.String("auth-token", defaultAuthToken(), "optional shared token for Basic/Bearer auth")
	flag.Parse()

	if err := os.MkdirAll(*dataDir, 0o755); err != nil {
		log.Fatalf("create data dir: %v", err)
	}

	srv, err := server.Open(*dataDir)
	if err != nil {
		log.Fatalf("open server: %v", err)
	}
	defer srv.Close()

	log.Printf("Codec sync server")
	log.Printf("  data: %s", *dataDir)
	log.Printf("  listen: %s", *addr)
	if strings.TrimSpace(*webDir) != "" {
		log.Printf("  web: %s", *webDir)
	} else {
		log.Printf("  web: disabled, run bun run build or pass --web")
	}
	if strings.TrimSpace(*authToken) != "" {
		log.Printf("  auth: enabled (token hidden)")
	} else {
		log.Printf("  auth: disabled")
	}
	for _, url := range advertisedURLs(*addr) {
		log.Printf("  open Codec: %s", url)
	}
	log.Printf("  health: /health")
	log.Printf("  library: /api/v1/library")
	log.Printf("  logs: METHOD path -> status bytes duration")
	handler := srv.HandlerWithOptions(server.HandlerOptions{
		WebDir:    *webDir,
		AuthToken: *authToken,
	})
	if err := http.ListenAndServe(*addr, handler); err != nil {
		log.Fatal(err)
	}
}

func defaultAuthToken() string {
	if token := strings.TrimSpace(os.Getenv("CODEC_AUTH_TOKEN")); token != "" {
		return token
	}
	return os.Getenv("LOUD_AUTH_TOKEN")
}

func defaultWebDir() string {
	candidates := []string{"../build", "./build"}
	if executable, err := os.Executable(); err == nil {
		dir := filepath.Dir(executable)
		candidates = append(candidates, filepath.Join(dir, "build"), filepath.Join(dir, "../build"))
	}

	for _, candidate := range candidates {
		if stat, err := os.Stat(filepath.Join(candidate, "index.html")); err == nil && !stat.IsDir() {
			absolute, err := filepath.Abs(candidate)
			if err != nil {
				return candidate
			}
			return absolute
		}
	}
	return ""
}

func advertisedURLs(addr string) []string {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		if strings.HasPrefix(addr, ":") {
			host = ""
			port = strings.TrimPrefix(addr, ":")
		} else {
			return []string{"http://" + addr}
		}
	}

	if port == "" {
		port = "8787"
	}

	if host != "" && host != "0.0.0.0" && host != "::" {
		return []string{"http://" + net.JoinHostPort(host, port)}
	}

	urls := []string{"http://" + net.JoinHostPort("127.0.0.1", port)}
	for _, ip := range advertisedIPv4s() {
		urls = append(urls, "http://"+net.JoinHostPort(ip, port))
	}
	return urls
}

func advertisedIPv4s() []string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}

	var ips []string
	seen := map[string]bool{}
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP == nil || ipNet.IP.IsLoopback() {
			continue
		}
		ip := ipNet.IP.To4()
		if ip == nil || ip.IsLinkLocalUnicast() || !ip.IsGlobalUnicast() {
			continue
		}
		value := ip.String()
		if seen[value] {
			continue
		}
		seen[value] = true
		ips = append(ips, value)
	}
	return ips
}
