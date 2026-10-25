package main

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/route/rule"
)

func TestWifiStateValidationAndConcurrency(t *testing.T) {
	for _, input := range []string{`{`, `{"type":"vpn"}`, `{"type":"wifi","ssid":"` + strings.Repeat("x", 33) + `"}`, `{"type":"wifi","ssid":"bad\u0000name"}`} {
		if _, err := parsePhysicalNetworkState(input); err == nil {
			t.Fatal("accepted invalid network state")
		}
	}
	state, err := parsePhysicalNetworkState(`{"type":"cellular","ssid":"stale"}`)
	if err != nil || state.SSID != "" {
		t.Fatal("cellular retained a stale Wi-Fi name")
	}
	p := &harmonyPlatform{}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				p.setNetworkState(physicalNetworkState{Type: "wifi", SSID: "test"})
				value := p.ReadWIFIState()
				value.SSID = "mutated"
				_ = p.networkType()
			}
		}()
	}
	wg.Wait()
	if p.ReadWIFIState().SSID != "test" {
		t.Fatal("caller mutated platform Wi-Fi state")
	}
}

func TestRealDaemonWifiRulesAndNetworkType(t *testing.T) {
	dir := t.TempDir()
	if err := libbox.Setup(&libbox.SetupOptions{BasePath: dir, WorkingPath: dir, TempPath: dir, LogMaxLines: 100, OomKillerDisabled: true}); err != nil {
		t.Fatal(err)
	}
	interfaces, err := nativeInterfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatal("no native interface")
	}
	p := &harmonyPlatform{iface: interfaces[0].Name, networkState: physicalNetworkState{Type: "wifi", SSID: "Home-test"}}
	server, err := libbox.NewCommandServer(&commandHandler{}, p)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = server.CloseService()
		server.Close()
		running = nil
		activePlatform = nil
		activeLogRedactions = nil
	}()
	profile := `{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","rules":[{"wifi_ssid":["Home-test"],"action":"route","outbound":"direct"},{"network_type":["wifi"],"action":"route","outbound":"direct"}]},"dns":{"servers":[{"type":"udp","tag":"test","server":"192.0.2.1"}],"rules":[{"wifi_ssid":["Home-test"],"action":"route","server":"test"}]},"log":{"level":"info","output":"/dev/null"}}`
	if err = server.StartOrReloadService(profile, &libbox.OverrideOptions{}); err != nil {
		t.Fatal(err)
	}
	running, activePlatform = server, p
	activeLogRedactions = logRedactions(profile)
	network := server.Instance().Box().Network()
	if !server.NeedWIFIState() || network.WIFIState().SSID != "Home-test" {
		t.Fatal("initial SSID did not reach real daemon")
	}
	item := rule.NewWIFISSIDItem(network, []string{"Home-test"})
	if !item.Match(&adapter.InboundContext{}) {
		t.Fatal("real SSID rule did not match")
	}
	if network.DefaultNetworkInterface() == nil || int32(network.DefaultNetworkInterface().Type) != libbox.InterfaceTypeWIFI {
		t.Fatal("physical interface type did not reach real daemon")
	}
	call := func(input string) controlReply {
		t.Helper()
		var r controlReply
		if err := json.Unmarshal([]byte(coreControl(input)), &r); err != nil {
			t.Fatal(err)
		}
		return r
	}
	if !call(`{"action":"wifi-state","network":{"type":"wifi","ssid":"Away-test"}}`).OK || item.Match(&adapter.InboundContext{}) {
		t.Fatal("same-interface SSID change left old rule matching")
	}
	if !call(`{"action":"wifi-state","network":{"type":"wifi","ssid":""}}`).OK || network.WIFIState().SSID != "" {
		t.Fatal("unreadable SSID did not clear cached match")
	}
	if !call(`{"action":"wifi-state","network":{"type":"cellular","ssid":"Home-test"}}`).OK || network.WIFIState().SSID != "" {
		t.Fatal("cellular retained SSID")
	}
	if call(`{"action":"wifi-state","network":{"type":"invalid","ssid":"Home-test"}}`).OK {
		t.Fatal("accepted invalid live update")
	}
	if strings.Contains(safeLog("wifi_ssid=Home-test"), "Home-test") {
		t.Fatal("configured SSID escaped log redaction")
	}
}
