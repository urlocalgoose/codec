// First-run setup doubles as the installer: one download holds the server,
// the web app, and the desktop app, and the questions decide what gets
// installed where — desktop app into Applications, server into ~/.codec with
// a config file and (optionally) a login service. Flags and env vars always
// win over the saved config.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

type serverConfig struct {
	Addr      string `json:"addr,omitempty"`
	DataDir   string `json:"data_dir,omitempty"`
	WebDir    string `json:"web_dir,omitempty"`
	AuthToken string `json:"auth_token,omitempty"`
}

func codecHome() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codec")
}

func configPath() string {
	if codecHome() == "" {
		return ""
	}
	return filepath.Join(codecHome(), "server.json")
}

func loadConfig() *serverConfig {
	path := configPath()
	if path == "" {
		return nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var cfg serverConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil
	}
	return &cfg
}

func saveConfig(cfg serverConfig) (string, error) {
	path := configPath()
	if path == "" {
		return "", fmt.Errorf("could not resolve a home directory for the config file")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return "", err
	}
	// 0600: the file holds the auth token.
	return path, os.WriteFile(path, append(raw, '\n'), 0o600)
}

func stdinIsTerminal() bool {
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func generateToken() string {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return ""
	}
	return hex.EncodeToString(raw)
}

func hasExistingLibrary(dataDir string) bool {
	for _, name := range []string{"codec-sync.sqlite", "loud-sync.sqlite"} {
		if info, err := os.Stat(filepath.Join(dataDir, name)); err == nil && info.Size() > 0 {
			return true
		}
	}
	return false
}

// setupOutcome tells main whether to keep serving in the foreground.
type setupOutcome struct {
	config        serverConfig
	runServer     bool
	serviceActive bool
}

func runSetupWizard(defaults serverConfig) (setupOutcome, error) {
	reader := bufio.NewReader(os.Stdin)
	ask := func(question, fallback string) (string, error) {
		if fallback != "" {
			fmt.Printf("%s [%s]: ", question, fallback)
		} else {
			fmt.Printf("%s: ", question)
		}
		line, err := reader.ReadString('\n')
		if err != nil && line == "" {
			return "", err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			return fallback, nil
		}
		return line, nil
	}
	yes := func(answer string) bool { return strings.HasPrefix(strings.ToLower(answer), "y") }

	outcome := setupOutcome{config: defaults}
	fmt.Println()
	fmt.Println("Codec setup — a few questions, then everything's installed.")
	fmt.Println()

	// --- Desktop app -------------------------------------------------------
	if bundle := findDesktopBundle(); bundle != "" {
		answer, err := ask("Install the Codec desktop app on this computer? (yes/no)", "yes")
		if err != nil {
			return outcome, err
		}
		if yes(answer) {
			installed, err := installDesktopApp(bundle)
			if err != nil {
				fmt.Printf("  Couldn't install the desktop app: %v\n", err)
			} else {
				fmt.Printf("  Desktop app installed: %s\n", installed)
			}
		}
	}

	// --- Server ------------------------------------------------------------
	answer, err := ask("Run the Codec server on this computer, so your phone and other devices can stream? (yes/no)", "yes")
	if err != nil {
		return outcome, err
	}
	if !yes(answer) {
		fmt.Println()
		fmt.Println("Skipping the server. Open the desktop app and point it at a music")
		fmt.Println("folder, or at a server running somewhere else.")
		return outcome, nil
	}
	outcome.runServer = true

	cfg := &outcome.config
	if cfg.DataDir == "" && codecHome() != "" {
		cfg.DataDir = filepath.Join(codecHome(), "data")
	} else if cfg.DataDir == "" {
		cfg.DataDir = "./codec-sync-data"
	}
	if cfg.Addr == "" {
		cfg.Addr = ":8787"
	}

	dataDir, err := ask("Where should Codec keep your music and database?", cfg.DataDir)
	if err != nil {
		return outcome, err
	}
	cfg.DataDir = dataDir
	if hasExistingLibrary(dataDir) {
		fmt.Println()
		fmt.Println("  Found an existing Codec library in that folder — this server will")
		fmt.Println("  serve it. If another server already runs against it, stop one of")
		fmt.Println("  them: two servers sharing a library confuses shared playback.")
	}

	port, err := ask("What port should the server listen on?", strings.TrimPrefix(cfg.Addr, ":"))
	if err != nil {
		return outcome, err
	}
	cfg.Addr = ":" + strings.TrimPrefix(strings.TrimSpace(port), ":")

	fmt.Println()
	fmt.Println("An auth token locks the server so only you (and devices you give")
	fmt.Println("the token to) can reach your music. Skip it only on a trusted LAN.")
	answer, err = ask("Protect the server with a token? (yes/no)", "yes")
	if err != nil {
		return outcome, err
	}
	if yes(answer) {
		token, err := ask("Paste a token, or press Enter to generate one", "")
		if err != nil {
			return outcome, err
		}
		if token == "" {
			token = generateToken()
		}
		cfg.AuthToken = token
	} else {
		cfg.AuthToken = ""
	}

	// Server + web app move to ~/.codec so the service and later launches
	// don't depend on where the download landed.
	if installed, webDir, err := installServerFiles(); err != nil {
		fmt.Printf("  Couldn't copy the server into %s: %v (running from here instead)\n", codecHome(), err)
	} else {
		cfg.WebDir = webDir
		fmt.Printf("  Server installed: %s\n", installed)
	}

	path, err := saveConfig(*cfg)
	if err != nil {
		return outcome, err
	}
	fmt.Printf("  Settings saved: %s (run with --setup to change them)\n", path)

	// --- Login service -------------------------------------------------------
	answer, err = ask("Start the server automatically when you log in? (yes/no)", "yes")
	if err != nil {
		return outcome, err
	}
	if yes(answer) {
		if err := installLoginService(*cfg); err != nil {
			fmt.Printf("  Couldn't set up autostart: %v — the server will run in this window instead.\n", err)
		} else {
			outcome.serviceActive = true
			fmt.Println("  Autostart set up; the server is running in the background now.")
		}
	}

	fmt.Println()
	for _, url := range advertisedURLs(cfg.Addr) {
		fmt.Printf("  Open Codec: %s\n", url)
	}
	if cfg.AuthToken != "" {
		fmt.Println()
		fmt.Println("  Your token (paste it into each app; it's also in the settings file):")
		fmt.Println()
		fmt.Printf("    %s\n", cfg.AuthToken)
	}
	fmt.Println()
	return outcome, nil
}

// --- Locating and installing the pieces ---------------------------------------

func executableDir() string {
	executable, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(executable)
}

// findDesktopBundle looks next to the binary for the platform's desktop app.
func findDesktopBundle() string {
	dir := executableDir()
	var patterns []string
	switch runtime.GOOS {
	case "darwin":
		patterns = []string{"Codec.app"}
	case "linux":
		patterns = []string{"Codec*.AppImage", "codec*.AppImage"}
	case "windows":
		patterns = []string{"Codec*-setup.exe", "Codec*setup*.exe"}
	}
	for _, pattern := range patterns {
		if matches, _ := filepath.Glob(filepath.Join(dir, pattern)); len(matches) > 0 {
			return matches[0]
		}
	}
	return ""
}

func installDesktopApp(bundle string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	switch runtime.GOOS {
	case "darwin":
		// ~/Applications is per-user and never needs admin; Spotlight and
		// the Dock treat it like /Applications.
		target := filepath.Join(home, "Applications", "Codec.app")
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return "", err
		}
		os.RemoveAll(target)
		if out, err := exec.Command("ditto", bundle, target).CombinedOutput(); err != nil {
			return "", fmt.Errorf("ditto: %v %s", err, strings.TrimSpace(string(out)))
		}
		exec.Command("xattr", "-dr", "com.apple.quarantine", target).Run()
		return target, nil
	case "linux":
		binDir := filepath.Join(home, ".local", "bin")
		if err := os.MkdirAll(binDir, 0o755); err != nil {
			return "", err
		}
		target := filepath.Join(binDir, "codec-desktop")
		if err := copyFile(bundle, target, 0o755); err != nil {
			return "", err
		}
		appsDir := filepath.Join(home, ".local", "share", "applications")
		if err := os.MkdirAll(appsDir, 0o755); err == nil {
			entry := "[Desktop Entry]\nType=Application\nName=Codec\nExec=" + target + "\nCategories=AudioVideo;Audio;Player;\nTerminal=false\n"
			os.WriteFile(filepath.Join(appsDir, "codec.desktop"), []byte(entry), 0o644)
		}
		return target, nil
	case "windows":
		// The NSIS installer knows how to install itself; run it silently.
		if out, err := exec.Command(bundle, "/S").CombinedOutput(); err != nil {
			return "", fmt.Errorf("installer: %v %s", err, strings.TrimSpace(string(out)))
		}
		return "Codec (via installer)", nil
	}
	return "", fmt.Errorf("no desktop install path for %s", runtime.GOOS)
}

// installServerFiles copies this binary and the web app into ~/.codec.
func installServerFiles() (string, string, error) {
	home := codecHome()
	if home == "" {
		return "", "", fmt.Errorf("no home directory")
	}
	executable, err := os.Executable()
	if err != nil {
		return "", "", err
	}
	binDir := filepath.Join(home, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return "", "", err
	}
	target := filepath.Join(binDir, filepath.Base(executable))
	if absSource, _ := filepath.Abs(executable); absSource != target {
		if err := copyFile(executable, target, 0o755); err != nil {
			return "", "", err
		}
	}

	webDir := ""
	if source := defaultWebDir(); source != "" {
		webDir = filepath.Join(home, "web")
		if abs, _ := filepath.Abs(source); abs != webDir {
			os.RemoveAll(webDir)
			if err := copyTree(source, webDir); err != nil {
				return "", "", err
			}
		}
	}
	return target, webDir, nil
}

// installLoginService registers the installed server to start at login and
// starts it now. Platform-native, no dependencies.
func installLoginService(cfg serverConfig) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	binary := filepath.Join(codecHome(), "bin", filepath.Base(mustExecutable()))
	switch runtime.GOOS {
	case "darwin":
		dir := filepath.Join(home, "Library", "LaunchAgents")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		plist := filepath.Join(dir, "codec.server.plist")
		logs := filepath.Join(codecHome(), "logs")
		os.MkdirAll(logs, 0o755)
		content := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>codec.server</string>
  <key>ProgramArguments</key><array><string>%s</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>%s/server.log</string>
  <key>StandardErrorPath</key><string>%s/server.log</string>
</dict>
</plist>
`, binary, logs, logs)
		if err := os.WriteFile(plist, []byte(content), 0o644); err != nil {
			return err
		}
		exec.Command("launchctl", "bootout", fmt.Sprintf("gui/%d/codec.server", os.Getuid())).Run()
		if out, err := exec.Command("launchctl", "bootstrap", fmt.Sprintf("gui/%d", os.Getuid()), plist).CombinedOutput(); err != nil {
			return fmt.Errorf("launchctl: %v %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	case "linux":
		dir := filepath.Join(home, ".config", "systemd", "user")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		unit := filepath.Join(dir, "codec-server.service")
		content := fmt.Sprintf("[Unit]\nDescription=Codec sync server\nAfter=network.target\n\n[Service]\nExecStart=%s\nRestart=always\n\n[Install]\nWantedBy=default.target\n", binary)
		if err := os.WriteFile(unit, []byte(content), 0o644); err != nil {
			return err
		}
		if out, err := exec.Command("systemctl", "--user", "enable", "--now", "codec-server.service").CombinedOutput(); err != nil {
			return fmt.Errorf("systemctl: %v %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	case "windows":
		startup := filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
		if err := os.MkdirAll(startup, 0o755); err != nil {
			return err
		}
		script := filepath.Join(startup, "codec-server.cmd")
		if err := os.WriteFile(script, []byte("@echo off\r\nstart \"Codec\" /min \""+binary+"\"\r\n"), 0o644); err != nil {
			return err
		}
		return exec.Command("cmd", "/C", "start", "", "/min", binary).Start()
	}
	return fmt.Errorf("no autostart support for %s", runtime.GOOS)
}

func mustExecutable() string {
	executable, err := os.Executable()
	if err != nil {
		return "codec-sync-server"
	}
	return executable
}

func copyFile(source, target string, mode os.FileMode) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := target + ".part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	out.Close()
	return os.Rename(tmp, target)
}

func copyTree(source, target string) error {
	return filepath.Walk(source, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		destination := filepath.Join(target, relative)
		if info.IsDir() {
			return os.MkdirAll(destination, 0o755)
		}
		return copyFile(path, destination, info.Mode().Perm()|0o600)
	})
}
