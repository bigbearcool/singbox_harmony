package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/experimental/libbox"
)

const directProfile = `{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`

func TestDualStackAndDNSInvariants(t *testing.T) {
	input := `{"outbounds":[{"type":"direct","tag":"egress"}],"inbounds":[{"type":"mixed","listen":"0.0.0.0","listen_port":1080}],"route":{"auto_detect_interface":true,"default_interface":"wlan0","final":"egress","rules":[{"domain_suffix":["example.org"],"outbound":"egress"}]},"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090"}}}`
	text, err := normalizeConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	var cfg struct {
		Inbounds []struct {
			Type      string   `json:"type"`
			Address   []string `json:"address"`
			AutoRoute bool     `json:"auto_route"`
			MTU       int      `json:"mtu"`
		} `json:"inbounds"`
		Experimental json.RawMessage `json:"experimental"`
		Route        struct {
			Final     string                       `json:"final"`
			Auto      bool                         `json:"auto_detect_interface"`
			Interface string                       `json:"default_interface"`
			Rules     []map[string]json.RawMessage `json:"rules"`
		} `json:"route"`
	}
	if err := json.Unmarshal([]byte(text), &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Inbounds) != 1 || cfg.Inbounds[0].Type != "tun" || len(cfg.Inbounds[0].Address) != 2 || !strings.Contains(cfg.Inbounds[0].Address[1], ":") {
		t.Fatal("missing dual-stack TUN")
	}
	if cfg.Inbounds[0].AutoRoute || cfg.Inbounds[0].MTU != 1280 || cfg.Route.Auto || cfg.Route.Interface != "" {
		t.Fatal("system-owned routing overridden")
	}
	if len(cfg.Experimental) > 0 || cfg.Route.Final != "egress" || len(cfg.Route.Rules) != 3 {
		t.Fatal("profile rules not preserved or remote API exposed")
	}
	if string(cfg.Route.Rules[1]["action"]) != `"hijack-dns"` {
		t.Fatal("DNS port bypasses core")
	}
}

func TestCoreAcceptsNormalizedProfile(t *testing.T) {
	text, err := normalizeConfig(directProfile)
	if err != nil {
		t.Fatal(err)
	}
	if err = libbox.CheckConfig(text); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsInvalidAndUnsupportedProfiles(t *testing.T) {
	for _, input := range []string{`null`, `[]`, `{}`, `{"outbounds":[]}`, `{"outbounds":[{"type":"direct"}],"route":"invalid"}`, `{"outbounds":[{"type":"direct"}],"services":[{"type":"ssm-api"}]}`} {
		if _, err := normalizeConfig(input); err == nil {
			t.Fatalf("unexpectedly accepted %s", input)
		}
	}
}

func TestPreservesCustomDNSResolver(t *testing.T) {
	input := `{"outbounds":[{"type":"direct","tag":"direct"}],"dns":{"servers":[{"type":"https","tag":"mydns","server":"1.1.1.1"}],"final":"mydns"},"route":{"final":"direct"}}`
	text, err := normalizeConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, `"default_domain_resolver":{"server":"mydns"}`) {
		t.Fatal(text)
	}
	if err := libbox.CheckConfig(text); err != nil {
		t.Fatal(err)
	}
}
