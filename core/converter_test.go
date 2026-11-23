package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/experimental/libbox"
)

func verifyConvertedProfile(t *testing.T, converted string) map[string]any {
	t.Helper()
	normalized, err := normalizeConfig(converted)
	if err != nil {
		t.Fatalf("normalizeConfig failed: %v\nconfig:\n%s", err, converted)
	}
	if err := libbox.CheckConfig(normalized); err != nil {
		t.Fatalf("libbox.CheckConfig failed: %v\nconfig:\n%s", err, converted)
	}
	var root map[string]any
	if err := json.Unmarshal([]byte(converted), &root); err != nil {
		t.Fatalf("unmarshal converted JSON failed: %v", err)
	}
	return root
}

func TestConvertAllProtocols(t *testing.T) {
	vmessJSON := `{"v":"2","ps":"VMess-WS","add":"vmess.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.example.com","path":"/ws","tls":"tls","sni":"vmess.example.com","alpn":"h2,http/1.1","fp":"chrome"}`
	vmessURI := "vmess://" + base64.StdEncoding.EncodeToString([]byte(vmessJSON))

	ssSIP002 := "ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-256-gcm:secret-pass")) + "@ss1.example.com:8388?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#SS-SIP002"
	ssLegacy := "ss://" + base64.StdEncoding.EncodeToString([]byte("chacha20-ietf-poly1305:legacy-pass@ss2.example.com:8389")) + "#SS-Legacy"

	lines := []string{
		"vless://11111111-2222-3333-4444-555555555555@vless.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=01020304&type=tcp#VLESS-Reality",
		"vless://11111111-2222-3333-4444-555555555555@vless-ws.example.com:443?security=tls&sni=vless-ws.example.com&type=ws&host=vless-ws.example.com&path=%2Fchat#VLESS-WS",
		vmessURI,
		"trojan://trojan-pass@trojan.example.com:443?security=tls&sni=trojan.example.com&type=grpc&serviceName=grpcSvc&alpn=h2#Trojan-gRPC",
		ssSIP002,
		ssLegacy,
		"hy2://hy2-pass@hy2.example.com:443?sni=hy2.example.com&insecure=1&obfs=salamander&obfs-password=obfspass#HY2-Node",
		"hysteria2://hy2-pass2@hy2b.example.com:8443?sni=hy2b.example.com#Hysteria2-Node",
		"tuic://11111111-2222-3333-4444-555555555555:tuic-pass@tuic.example.com:443?sni=tuic.example.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&reduce_rtt=1#TUIC-Node",
	}

	converted, err := convertSubscriptionToSingbox(strings.Join(lines, "\n"))
	if err != nil {
		t.Fatalf("convertSubscriptionToSingbox failed: %v", err)
	}
	root := verifyConvertedProfile(t, converted)

	outbounds, ok := root["outbounds"].([]any)
	if !ok {
		t.Fatalf("missing outbounds array")
	}
	// Proxy + Auto + 9 nodes + direct = 12
	if len(outbounds) != 12 {
		t.Fatalf("expected 12 outbounds, got %d", len(outbounds))
	}

	first := outbounds[0].(map[string]any)
	if first["type"] != "selector" || first["tag"] != "Proxy" {
		t.Fatalf("expected Proxy selector first, got %+v", first)
	}
	second := outbounds[1].(map[string]any)
	if second["type"] != "urltest" || second["tag"] != "Auto" {
		t.Fatalf("expected Auto urltest second, got %+v", second)
	}
	last := outbounds[len(outbounds)-1].(map[string]any)
	if last["type"] != "direct" || last["tag"] != "direct" {
		t.Fatalf("expected direct outbound last, got %+v", last)
	}

	route, ok := root["route"].(map[string]any)
	if !ok || route["final"] != "Proxy" || route["auto_detect_interface"] != true {
		t.Fatalf("unexpected route section: %+v", route)
	}
}

func TestConvertBase64Subscription(t *testing.T) {
	raw := strings.Join([]string{
		"trojan://pass1@t1.example.com:443?sni=t1.example.com#Node-A",
		"hy2://pass2@h1.example.com:443?sni=h1.example.com#Node-B",
	}, "\n")

	for name, encoded := range map[string]string{
		"std-base64":     base64.StdEncoding.EncodeToString([]byte(raw)),
		"raw-url-base64": base64.RawURLEncoding.EncodeToString([]byte(raw)),
	} {
		t.Run(name, func(t *testing.T) {
			converted, count, err := convertSubscriptionWithCount(encoded)
			if err != nil {
				t.Fatalf("%s failed: %v", name, err)
			}
			if count != 2 {
				t.Fatalf("expected 2 nodes, got %d", count)
			}
			verifyConvertedProfile(t, converted)
		})
	}
}

func TestConvertTagDeduplicationAndReservedNames(t *testing.T) {
	raw := strings.Join([]string{
		"trojan://p1@a.example.com:443#HK",
		"trojan://p2@b.example.com:443#HK",
		"trojan://p3@c.example.com:443#HK",
		"trojan://p4@d.example.com:443#Proxy",
		"trojan://p5@e.example.com:443#direct",
	}, "\n")

	converted, count, err := convertSubscriptionWithCount(raw)
	if err != nil {
		t.Fatalf("convertSubscriptionWithCount failed: %v", err)
	}
	if count != 5 {
		t.Fatalf("expected 5 nodes, got %d", count)
	}
	root := verifyConvertedProfile(t, converted)

	outbounds := root["outbounds"].([]any)
	tags := map[string]int{}
	for _, item := range outbounds {
		tag := item.(map[string]any)["tag"].(string)
		tags[tag]++
	}
	for tag, n := range tags {
		if n != 1 {
			t.Fatalf("duplicate tag %q appeared %d times", tag, n)
		}
	}
	for _, expected := range []string{"HK", "HK-2", "HK-3", "Proxy-2", "direct-2"} {
		if tags[expected] != 1 {
			t.Fatalf("expected deduplicated tag %q to exist, got tags: %+v", expected, tags)
		}
	}
}

func TestConvertRejectsInvalidInput(t *testing.T) {
	for _, bad := range []string{
		"",
		"   \n\t  ",
		"not a valid subscription at all",
		base64.StdEncoding.EncodeToString([]byte("hello world without any scheme")),
		"http://example.com/not-a-proxy",
		"vless://missing-port@example.com",
		"vmess://not-valid-base64!!!",
	} {
		if _, err := convertSubscriptionToSingbox(bad); err == nil {
			t.Fatalf("expected error for invalid input %q, got nil", bad)
		}
	}
}

func TestCoreControlConvertProfileWhileStopped(t *testing.T) {
	prevRunning := running
	running = nil
	defer func() { running = prevRunning }()

	sub := strings.Join([]string{
		"vless://11111111-2222-3333-4444-555555555555@v.example.com:443?security=tls&sni=v.example.com#Node-1",
		"trojan://pass@t.example.com:443?sni=t.example.com#Node-2",
	}, "\n")
	reqBytes, err := json.Marshal(controlRequest{
		Action:  "convert-profile",
		Content: base64.StdEncoding.EncodeToString([]byte(sub)),
	})
	if err != nil {
		t.Fatal(err)
	}

	rawReply := coreControl(string(reqBytes))
	var reply controlReply
	if err := json.Unmarshal([]byte(rawReply), &reply); err != nil {
		t.Fatalf("unmarshal reply failed: %v", err)
	}
	if !reply.OK {
		t.Fatalf("expected convert-profile to succeed while stopped, got reply: %+v", reply)
	}
	if reply.Message != "已转换 2 个节点" {
		t.Fatalf("unexpected message: %q", reply.Message)
	}
	if reply.Converted == "" {
		t.Fatal("expected non-empty converted JSON")
	}
	verifyConvertedProfile(t, reply.Converted)
}
