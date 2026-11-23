package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sbjson "github.com/sagernet/sing/common/json"
)

const proxyAndDirectProfile = `{
	"outbounds": [
		{"type": "socks", "tag": "proxy-main", "server": "198.51.100.10", "server_port": 1080},
		{"type": "direct", "tag": "direct-out"}
	],
	"dns": {
		"servers": [{"type": "https", "tag": "remote-dns", "server": "223.5.5.5"}],
		"rules": [{"domain_suffix": ["existing.example"], "server": "remote-dns"}],
		"final": "remote-dns"
	},
	"route": {
		"final": "proxy-main",
		"rules": [
			{"domain_suffix": ["sub.example.com"], "outbound": "proxy-main"}
		]
	}
}`

func TestApplyLocalOverridesDisabledPassthrough(t *testing.T) {
	normalized, err := normalizeConfig(proxyAndDirectProfile)
	if err != nil {
		t.Fatal(err)
	}
	got, err := applyLocalOverrides(normalized, LocalOverrides{
		Enabled:       false,
		RejectDomains: []string{"ads.example.com"},
		DirectDomains: []string{"cn.example.com"},
		Hosts:         []HostOverride{{Domain: "intranet.local", IPs: []string{"10.0.0.1"}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got != normalized {
		t.Fatal("disabled overrides must return normalizedConfig unchanged")
	}
}

func TestApplyLocalOverridesRoutePrecedenceAndCheckConfig(t *testing.T) {
	normalized, err := normalizeConfig(proxyAndDirectProfile)
	if err != nil {
		t.Fatal(err)
	}
	overrides := LocalOverrides{
		Enabled:       true,
		RejectDomains: []string{"ads.example.com", " ", "ADS.EXAMPLE.COM"},
		RejectCidrs:   []string{"203.0.113.0/24", "invalid-cidr"},
		DirectDomains: []string{"corp.internal"},
		DirectCidrs:   []string{"10.0.0.0/8", "10.0.0.1"},
		ProxyDomains:  []string{"api.openai.com"},
		ProxyCidrs:    []string{"198.51.100.0/24", "2001:db8::/32"},
	}
	applied, err := applyLocalOverrides(normalized, overrides)
	if err != nil {
		t.Fatal(err)
	}
	if err := libbox.CheckConfig(applied); err != nil {
		t.Fatalf("libbox.CheckConfig failed: %v\nconfig: %s", err, applied)
	}

	var parsed struct {
		Route struct {
			Rules []struct {
				Protocol     string   `json:"protocol"`
				Port         int      `json:"port"`
				Action       string   `json:"action"`
				Outbound     string   `json:"outbound"`
				DomainSuffix []string `json:"domain_suffix"`
				IPCIDR       []string `json:"ip_cidr"`
			} `json:"rules"`
		} `json:"route"`
	}
	if err := json.Unmarshal([]byte(applied), &parsed); err != nil {
		t.Fatal(err)
	}

	rules := parsed.Route.Rules
	// 2 hijack-dns + 6 override rules + 1 subscription rule = 9
	if len(rules) != 9 {
		t.Fatalf("expected 9 rules, got %d: %+v", len(rules), rules)
	}
	if rules[0].Action != "hijack-dns" || rules[0].Protocol != "dns" {
		t.Fatalf("rule[0] should remain protocol=dns hijack-dns, got %+v", rules[0])
	}
	if rules[1].Action != "hijack-dns" || rules[1].Port != 53 {
		t.Fatalf("rule[1] should remain port=53 hijack-dns, got %+v", rules[1])
	}
	// Reject domain & CIDR
	if rules[2].Action != "reject" || len(rules[2].DomainSuffix) != 1 || rules[2].DomainSuffix[0] != "ads.example.com" {
		t.Fatalf("unexpected reject domain rule: %+v", rules[2])
	}
	if rules[3].Action != "reject" || len(rules[3].IPCIDR) != 1 || rules[3].IPCIDR[0] != "203.0.113.0/24" {
		t.Fatalf("unexpected reject cidr rule: %+v", rules[3])
	}
	// Direct domain & CIDR
	if rules[4].Outbound != "direct-out" || len(rules[4].DomainSuffix) != 1 || rules[4].DomainSuffix[0] != "corp.internal" {
		t.Fatalf("unexpected direct domain rule: %+v", rules[4])
	}
	if rules[5].Outbound != "direct-out" || len(rules[5].IPCIDR) != 1 || rules[5].IPCIDR[0] != "10.0.0.0/8" {
		t.Fatalf("unexpected direct cidr rule: %+v", rules[5])
	}
	// Proxy domain & CIDR
	if rules[6].Outbound != "proxy-main" || len(rules[6].DomainSuffix) != 1 || rules[6].DomainSuffix[0] != "api.openai.com" {
		t.Fatalf("unexpected proxy domain rule: %+v", rules[6])
	}
	if rules[7].Outbound != "proxy-main" || len(rules[7].IPCIDR) != 2 {
		t.Fatalf("unexpected proxy cidr rule: %+v", rules[7])
	}
	// Original subscription rule remains last
	if rules[8].Outbound != "proxy-main" || len(rules[8].DomainSuffix) != 1 || rules[8].DomainSuffix[0] != "sub.example.com" {
		t.Fatalf("subscription rule should remain after overrides, got %+v", rules[8])
	}
}

func TestApplyLocalOverridesProxyTagFallbackAndDirectOnlyProfile(t *testing.T) {
	// Case 1: route.final is direct, should fallback to first non-direct/block/dns outbound.
	profileWithDirectFinal := `{
		"outbounds": [
			{"type": "direct", "tag": "direct"},
			{"type": "socks", "tag": "fallback-proxy", "server": "198.51.100.20", "server_port": 1080}
		],
		"route": {"final": "direct"}
	}`
	normalized, err := normalizeConfig(profileWithDirectFinal)
	if err != nil {
		t.Fatal(err)
	}
	applied, err := applyLocalOverrides(normalized, LocalOverrides{
		Enabled:      true,
		ProxyDomains: []string{"example.net"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := libbox.CheckConfig(applied); err != nil {
		t.Fatalf("libbox.CheckConfig failed: %v", err)
	}
	if !strings.Contains(applied, `"outbound":"fallback-proxy"`) {
		t.Fatalf("expected fallback-proxy outbound, got %s", applied)
	}

	// Case 2: direct-only profile has no proxy outbound -> proxy rules skipped, direct/reject still valid.
	directNorm, err := normalizeConfig(directProfile)
	if err != nil {
		t.Fatal(err)
	}
	directApplied, err := applyLocalOverrides(directNorm, LocalOverrides{
		Enabled:       true,
		ProxyDomains:  []string{"should-skip.example"},
		DirectDomains: []string{"direct.example"},
		RejectDomains: []string{"reject.example"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := libbox.CheckConfig(directApplied); err != nil {
		t.Fatalf("libbox.CheckConfig failed on direct-only profile: %v", err)
	}
	if strings.Contains(directApplied, "should-skip.example") {
		t.Fatal("proxy rule should be skipped when no proxy outbound exists")
	}
	if !strings.Contains(directApplied, "direct.example") || !strings.Contains(directApplied, "reject.example") {
		t.Fatal("direct and reject rules should still be injected")
	}
}

func TestApplyLocalOverridesHostsDNSAndRuntimeStart(t *testing.T) {
	normalized, err := normalizeConfig(proxyAndDirectProfile)
	if err != nil {
		t.Fatal(err)
	}
	applied, err := applyLocalOverrides(normalized, LocalOverrides{
		Enabled: true,
		Hosts: []HostOverride{
			{Domain: " Intranet.Local. ", IPs: []string{"10.10.0.5", "not-an-ip", "fd00::5", "10.10.0.5"}},
			{Domain: "empty.invalid", IPs: []string{"999.999.999.999", ""}},
			{Domain: "   ", IPs: []string{"127.0.0.1"}},
			{Domain: "db.local", IPs: []string{"192.168.1.50"}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := libbox.CheckConfig(applied); err != nil {
		t.Fatalf("libbox.CheckConfig failed for hosts DNS: %v\nconfig: %s", err, applied)
	}

	var parsed struct {
		DNS struct {
			Servers []struct {
				Type       string              `json:"type"`
				Tag        string              `json:"tag"`
				Predefined map[string][]string `json:"predefined"`
			} `json:"servers"`
			Rules []struct {
				Domain []string `json:"domain"`
				Server string   `json:"server"`
			} `json:"rules"`
		} `json:"dns"`
	}
	if err := json.Unmarshal([]byte(applied), &parsed); err != nil {
		t.Fatal(err)
	}

	foundServer := false
	for _, s := range parsed.DNS.Servers {
		if s.Tag == localHostsServerTag {
			foundServer = true
			if s.Type != "hosts" {
				t.Fatalf("expected type hosts, got %q", s.Type)
			}
			if got := s.Predefined["intranet.local"]; len(got) != 2 || got[0] != "10.10.0.5" || got[1] != "fd00::5" {
				t.Fatalf("unexpected predefined for intranet.local: %v", got)
			}
			if got := s.Predefined["db.local"]; len(got) != 1 || got[0] != "192.168.1.50" {
				t.Fatalf("unexpected predefined for db.local: %v", got)
			}
			if _, exists := s.Predefined["empty.invalid"]; exists {
				t.Fatal("domain with no valid IPs should be ignored")
			}
		}
	}
	if !foundServer {
		t.Fatal("missing local-hosts-override DNS server")
	}
	if len(parsed.DNS.Rules) != 2 {
		t.Fatalf("expected 2 DNS rules (override + existing), got %d", len(parsed.DNS.Rules))
	}
	if parsed.DNS.Rules[0].Server != localHostsServerTag || len(parsed.DNS.Rules[0].Domain) != 2 {
		t.Fatalf("top DNS rule should route host domains to local-hosts-override, got %+v", parsed.DNS.Rules[0])
	}

	// Verify real sing-box instance initialization with hosts DNS transport (no TUN inbound).
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(applied), &raw); err != nil {
		t.Fatal(err)
	}
	delete(raw, "inbounds")
	textBytes, _ := json.Marshal(raw)
	ctx := box.Context(context.Background(), include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	options, err := sbjson.UnmarshalExtendedContext[option.Options](ctx, textBytes)
	if err != nil {
		t.Fatalf("unmarshal options failed: %v", err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		t.Fatalf("box.New failed: %v", err)
	}
	defer instance.Close()
	if err := instance.Start(); err != nil {
		t.Fatalf("instance.Start failed: %v", err)
	}
}

func TestLoadLocalOverridesAndRuntimeSettingsIntegration(t *testing.T) {
	dir := t.TempDir()

	// Missing file -> zero value
	if got := loadLocalOverrides(dir); got.Enabled {
		t.Fatal("expected disabled overrides when file is missing")
	}

	// Invalid JSON -> zero value
	overridePath := filepath.Join(dir, "overrides.json")
	if err := os.WriteFile(overridePath, []byte(`{invalid json`), 0600); err != nil {
		t.Fatal(err)
	}
	if got := loadLocalOverrides(dir); got.Enabled {
		t.Fatal("expected disabled overrides for invalid JSON")
	}

	// Oversized file (> 256 KiB) -> zero value
	huge := `{"enabled":true,"directDomains":["` + strings.Repeat("a", maxOverridesBytes+100) + `"]}`
	if err := os.WriteFile(overridePath, []byte(huge), 0600); err != nil {
		t.Fatal(err)
	}
	if got := loadLocalOverrides(dir); got.Enabled {
		t.Fatal("expected disabled overrides for oversized file")
	}

	// Valid overrides.json WITHOUT settings.json -> runtimeSettings still applies overrides, never modifies profile.json
	profilePath := filepath.Join(dir, "profile.json")
	if err := os.WriteFile(profilePath, []byte(proxyAndDirectProfile), 0600); err != nil {
		t.Fatal(err)
	}
	validOverrides := `{"enabled":true,"directDomains":["cn.local"],"hosts":[{"domain":"nas.local","ips":["192.168.1.2"]}]}`
	if err := os.WriteFile(overridePath, []byte(validOverrides), 0600); err != nil {
		t.Fatal(err)
	}

	normalized, err := normalizeConfig(proxyAndDirectProfile)
	if err != nil {
		t.Fatal(err)
	}
	effective := runtimeSettings(normalized, dir)
	if err := libbox.CheckConfig(effective); err != nil {
		t.Fatalf("runtimeSettings output failed CheckConfig: %v", err)
	}
	if !strings.Contains(effective, `"cn.local"`) || !strings.Contains(effective, `"local-hosts-override"`) {
		t.Fatalf("runtimeSettings did not apply overrides when settings.json is absent: %s", effective)
	}

	// Confirm profile.json on disk is untouched
	afterProfile, err := os.ReadFile(profilePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(afterProfile) != proxyAndDirectProfile {
		t.Fatal("profile.json must never be modified")
	}

	// Invalid config string passed to runtimeSettings -> safe fallback without panic
	if got := runtimeSettings("not-json", dir); got != "not-json" {
		t.Fatalf("expected safe fallback on invalid config, got %q", got)
	}
}
