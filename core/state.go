package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/sagernet/sing-box/daemon"
)

var selectionStatePath string

func privateSnapshot(dir string) error {
	file, err := os.OpenFile(filepath.Join(dir, "configuration.json"), os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	// Upstream overwrites this existing inode; pre-creating it prevents its
	// default report permissions from broadening a profile's access mode.
	return file.Chmod(0600)
}

func runtimeSettings(config, dir string) string {
	result := config
	var settings struct {
		LogLevel string `json:"logLevel"`
	}
	if bytes, err := os.ReadFile(filepath.Join(dir, "settings.json")); err == nil && len(bytes) <= 4096 && json.Unmarshal(bytes, &settings) == nil {
		switch settings.LogLevel {
		case "debug", "info", "warn", "error":
			var root map[string]json.RawMessage
			if json.Unmarshal([]byte(result), &root) == nil && root != nil {
				root["log"], _ = json.Marshal(map[string]any{"level": settings.LogLevel, "timestamp": true, "output": "/dev/null"})
				if marshaled, err := json.Marshal(root); err == nil {
					result = string(marshaled)
				}
			}
		}
	}
	if overrides := loadLocalOverrides(dir); overrides.Enabled {
		if applied, err := applyLocalOverrides(result, overrides); err == nil {
			result = applied
		}
	}
	return result
}
func loadSelections() map[string]string {
	values := map[string]string{}
	if bytes, err := os.ReadFile(selectionStatePath); err == nil && len(bytes) <= 65536 {
		_ = json.Unmarshal(bytes, &values)
	}
	if values == nil {
		values = map[string]string{}
	}
	return values
}
func restoreSelections(config, dir string) {
	hash := sha256.Sum256([]byte(config))
	selectionStatePath = filepath.Join(dir, "selections-"+hex.EncodeToString(hash[:])+".json")
	for group, outbound := range loadSelections() {
		_, _ = running.SelectOutbound(context.Background(), &daemon.SelectOutboundRequest{GroupTag: group, OutboundTag: outbound})
	}
}
func saveSelection(group, outbound string) error {
	values := loadSelections()
	values[group] = outbound
	bytes, _ := json.Marshal(values)
	file, err := os.CreateTemp(filepath.Dir(selectionStatePath), ".selections-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(bytes); err != nil {
		file.Close()
		return err
	}
	if err = file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), selectionStatePath)
}
