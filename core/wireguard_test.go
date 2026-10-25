package main

import (
	"context"
	"errors"
	"net/netip"
	"strings"
	"testing"
)

func TestWireGuardProbeUsesOnlyConfiguredAllowedDNS(t *testing.T) {
	configureWireGuardDiagnostics(`{"endpoints":[{"type":"wireguard","tag":"home","peers":[{"allowed_ips":["10.8.0.0/24"]}]}],"dns":{"servers":[{"type":"udp","server":"10.8.0.1","detour":"home"},{"type":"udp","server":"192.0.2.1","detour":"other"}]}}`)
	defer func() { wireGuardTargets = nil; wireGuardProbes = map[string]wireGuardProbe{} }()
	if len(wireGuardTargets) != 1 || wireGuardTargets[0].dns != netip.MustParseAddrPort("10.8.0.1:53") {
		t.Fatal("did not select the endpoint's own configured resolver")
	}
	if !wireGuardTargets[0].covers(netip.MustParseAddr("10.8.0.1")) || wireGuardTargets[0].covers(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("DNS probe can escape AllowedIPs")
	}
	result := probeWireGuard(context.Background(), "home")
	if result.OK || result.DNSReply {
		t.Fatal("claimed a working tunnel without a running core")
	}
	if _, ok := wireGuardProbes["home"]; !ok {
		t.Fatal("probe failure was not retained for diagnostics")
	}
}
func TestWireGuardErrorClassesDoNotExposeDestinations(t *testing.T) {
	category, summary := wireGuardFailure(errors.New("dial udp secret.example.invalid:51820: permission denied"), false)
	if category != "socket-permission" || strings.Contains(summary, "secret.example.invalid") {
		t.Fatal("permission error classification is unsafe")
	}
	category, _ = wireGuardFailure(context.DeadlineExceeded, false)
	if category != "no-handshake" {
		t.Fatal("unconfirmed handshake shown as connected")
	}
	category, _ = wireGuardFailure(context.DeadlineExceeded, true)
	if category != "inner-timeout" {
		t.Fatal("inner DNS failure confused with missing handshake")
	}
}
