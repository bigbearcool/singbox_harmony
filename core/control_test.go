package main

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/daemon"
	"github.com/sagernet/sing-box/experimental/libbox"
)

func TestNativeControlsAndSelectionPersistence(t *testing.T) {
	dir := t.TempDir()
	if err := libbox.Setup(&libbox.SetupOptions{BasePath: dir, WorkingPath: dir, TempPath: dir, LogMaxLines: 100, OomKillerDisabled: true}); err != nil {
		t.Fatal(err)
	}
	interfaces, err := nativeInterfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatal("no native interface for control test")
	}
	server, err := libbox.NewCommandServer(&commandHandler{}, &harmonyPlatform{iface: interfaces[0].Name})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.CloseService(); server.Close() }()
	// Real daemon and selector, without TUN, listeners or remote destinations.
	profile := `{"outbounds":[{"type":"direct","tag":"a"},{"type":"direct","tag":"b"},{"type":"selector","tag":"pick","outbounds":["a","b"],"default":"a"}],"route":{"final":"pick"},"log":{"level":"warn","output":"/dev/null"}}`
	if err = server.StartOrReloadService(profile, &libbox.OverrideOptions{}); err != nil {
		t.Fatal(err)
	}
	running = server
	defer func() { running = nil; selectionStatePath = "" }()
	restoreSelections(profile, dir)
	call := func(input string) controlReply {
		t.Helper()
		var reply controlReply
		if err := json.Unmarshal([]byte(coreControl(input)), &reply); err != nil {
			t.Fatal(err)
		}
		return reply
	}
	if !call(`{"action":"select","group":"pick","outbound":"b"}`).OK {
		t.Fatal("selector action failed")
	}
	if info, err := os.Stat(selectionStatePath); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("selection state is not private")
	}
	_, _ = server.SelectOutbound(context.Background(), &daemon.SelectOutboundRequest{GroupTag: "pick", OutboundTag: "a"})
	restoreSelections(profile, dir)
	reply := call(`{"action":"snapshot"}`)
	if !reply.OK || reply.Data == nil || len(reply.Data.Groups) != 1 || reply.Data.Groups[0].Selected != "b" {
		t.Fatal("daemon snapshot did not restore the actual selection")
	}
	if call(`{"action":"select","group":"pick","outbound":"missing"}`).OK {
		t.Fatal("accepted nonexistent group member")
	}
	if call(`{"action":"unknown"}`).OK {
		t.Fatal("accepted unsupported control command")
	}
	if !call(`{"action":"close-all"}`).OK || !call(`{"action":"clear-logs"}`).OK {
		t.Fatal("maintenance action failed")
	}
	SBFree(SBStop())
	if server.Instance() != nil {
		t.Fatal("stopping the native core left the daemon instance alive")
	}
}

func TestLogsExcludeURLSecrets(t *testing.T) {
	value := safeLog(`GET https://user:password@example.invalid/config?token=abcdef password=hunter2 uuid=abc123 private_key="hidden"`)
	for _, secret := range []string{"abcdef", "hunter2", "abc123", "hidden", "user:password"} {
		if strings.Contains(value, secret) {
			t.Fatal("log contains a credential")
		}
	}
}

func TestPrivateSnapshotAndConfiguredLogValues(t *testing.T) {
	dir := t.TempDir()
	if err := privateSnapshot(dir); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(dir + "/configuration.json"); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("configuration snapshot is not private")
	}
	old := activeLogRedactions
	activeLogRedactions = logRedactions(`{"outbounds":[{"server":"node.example.invalid","uuid":"test-secret-uuid"}],"endpoints":[{"private_key":"test-secret-key"}]}`)
	defer func() { activeLogRedactions = old }()
	value := safeLog("node.example.invalid 192.0.2.44 [2001:db8::44] test-secret-uuid test-secret-key")
	for _, secret := range []string{"node.example.invalid", "192.0.2.44", "2001:db8::44", "test-secret-uuid", "test-secret-key"} {
		if strings.Contains(value, secret) {
			t.Fatal("configured endpoint or credential escaped redaction")
		}
	}
}
