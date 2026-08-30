// First-run setup: a small interactive wizard so a release download is
// "run it, answer three questions, listening." Answers persist to
// ~/.codec/server.json; flags and env vars always win over the file.
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type serverConfig struct {
	Addr      string `json:"addr,omitempty"`
	DataDir   string `json:"data_dir,omitempty"`
	WebDir    string `json:"web_dir,omitempty"`
	AuthToken string `json:"auth_token,omitempty"`
}

func configPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codec", "server.json")
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

func runSetupWizard(defaults serverConfig) (serverConfig, error) {
	reader := bufio.NewReader(os.Stdin)
	ask := func(question, fallback string) (string, error) {
		if fallback != "" {
			fmt.Printf("%s [%s]: ", question, fallback)
		} else {
			fmt.Printf("%s: ", question)
		}
		line, err := reader.ReadString('\n')
		if err != nil {
			return "", err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			return fallback, nil
		}
		return line, nil
	}

	fmt.Println()
	fmt.Println("Codec setup — three questions and you're listening.")
	fmt.Println()

	cfg := defaults
	if cfg.DataDir == "" {
		if home, err := os.UserHomeDir(); err == nil {
			cfg.DataDir = filepath.Join(home, ".codec", "data")
		} else {
			cfg.DataDir = "./codec-sync-data"
		}
	}
	if cfg.Addr == "" {
		cfg.Addr = ":8787"
	}

	dataDir, err := ask("Where should Codec keep your music and database?", cfg.DataDir)
	if err != nil {
		return cfg, err
	}
	cfg.DataDir = dataDir

	port, err := ask("What port should the server listen on?", strings.TrimPrefix(cfg.Addr, ":"))
	if err != nil {
		return cfg, err
	}
	cfg.Addr = ":" + strings.TrimPrefix(strings.TrimSpace(port), ":")

	fmt.Println()
	fmt.Println("An auth token locks the server so only you (and devices you give")
	fmt.Println("the token to) can reach your music. Skip it only on a trusted LAN.")
	answer, err := ask("Protect the server with a token? (yes/no)", "yes")
	if err != nil {
		return cfg, err
	}
	if strings.HasPrefix(strings.ToLower(answer), "y") {
		token, err := ask("Paste a token, or press Enter to generate one", "")
		if err != nil {
			return cfg, err
		}
		if token == "" {
			token = generateToken()
		}
		cfg.AuthToken = token
	} else {
		cfg.AuthToken = ""
	}

	path, err := saveConfig(cfg)
	if err != nil {
		return cfg, err
	}

	fmt.Println()
	fmt.Printf("Saved to %s — run with --setup to change answers later.\n", path)
	if cfg.AuthToken != "" {
		fmt.Println()
		fmt.Println("Your token (paste it into each app; it's also in the file above):")
		fmt.Println()
		fmt.Printf("  %s\n", cfg.AuthToken)
	}
	fmt.Println()
	return cfg, nil
}
