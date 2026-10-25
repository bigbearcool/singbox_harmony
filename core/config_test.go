package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sbjson "github.com/sagernet/sing/common/json"
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
	if cfg.Inbounds[0].AutoRoute || cfg.Inbounds[0].MTU != 1280 || !cfg.Route.Auto || cfg.Route.Interface != "" {
		t.Fatal("system-owned routing overridden")
	}
	if len(cfg.Experimental) > 0 || cfg.Route.Final != "egress" || len(cfg.Route.Rules) != 3 {
		t.Fatal("profile rules not preserved or remote API exposed")
	}
	if string(cfg.Route.Rules[1]["action"]) != `"hijack-dns"` {
		t.Fatal("DNS port bypasses core")
	}
}

// Start the real DNS transport with no TUN/listener, catching initialization
// errors that CheckConfig cannot catch. No DNS query is sent by this test.
func TestDirectDiagnosticDNSStarts(t *testing.T) {
	text, err := normalizeConfig(directProfile)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err = json.Unmarshal([]byte(text), &raw); err != nil {
		t.Fatal(err)
	}
	delete(raw, "inbounds")
	textBytes, _ := json.Marshal(raw)
	ctx := box.Context(context.Background(), include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	options, err := sbjson.UnmarshalExtendedContext[option.Options](ctx, textBytes)
	if err != nil {
		t.Fatal(err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if err = instance.Start(); err != nil {
		t.Fatal(err)
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

func TestDefaultDNSMatchesUnderlyingAddressFamily(t *testing.T) {
	for _, ipv6 := range []bool{false, true} {
		text, err := normalizeConfigForNetwork(directProfile, ipv6)
		if err != nil {
			t.Fatal(err)
		}
		var cfg struct {
			DNS struct {
				Servers []struct {
					Server string `json:"server"`
					Detour string `json:"detour"`
				} `json:"servers"`
			} `json:"dns"`
		}
		if err = json.Unmarshal([]byte(text), &cfg); err != nil {
			t.Fatal(err)
		}
		want := "223.5.5.5"
		if ipv6 {
			want = "2400:3200::1"
		}
		if len(cfg.DNS.Servers) != 1 || cfg.DNS.Servers[0].Server != want || cfg.DNS.Servers[0].Detour != "" {
			t.Fatal("invalid direct diagnostic resolver")
		}
	}
}

func TestIPv6NetworkKeepsExplicitDNS(t *testing.T) {
	input := `{"outbounds":[{"type":"direct","tag":"direct"}],"dns":{"servers":[{"type":"https","tag":"mydns","server":"9.9.9.9"}],"final":"mydns"},"route":{"final":"direct"}}`
	text, err := normalizeConfigForNetwork(input, true)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, `"server":"9.9.9.9"`) || strings.Contains(text, `2400:3200::1`) {
		t.Fatal("explicit DNS was replaced")
	}
}

func TestUserspaceWireGuardProfile(t *testing.T) {
	endpoint := `{"type":"wireguard","tag":"home","system":false,"address":["10.7.0.2/32"],"private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","peers":[{"address":"192.0.2.1","port":51820,"public_key":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=","allowed_ips":["10.7.0.0/24"]}]}`
	input := `{"outbounds":[{"type":"direct","tag":"direct"}],"endpoints":[` + endpoint + `],"route":{"final":"direct","rules":[{"ip_cidr":["10.7.0.0/24"],"outbound":"home"}]}}`
	text, err := normalizeConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, endpoint) || !strings.Contains(text, `"outbound":"home"`) {
		t.Fatal("WireGuard endpoint or its route was changed")
	}
	if err = libbox.CheckConfig(text); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		strings.Replace(input, `"system":false`, `"system":true`, 1),
		strings.Replace(input, `"system":false`, `"listen_port":51820`, 1),
		strings.Replace(input, `"type":"wireguard"`, `"type":"tailscale"`, 1),
	} {
		if _, err := normalizeConfig(bad); err == nil {
			t.Fatal("accepted a system endpoint or a listening endpoint")
		}
	}
}
