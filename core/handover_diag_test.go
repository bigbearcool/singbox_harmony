package main

import (
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gofrs/uuid/v5"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	"github.com/sagernet/sing-box/experimental/libbox"
	M "github.com/sagernet/sing/common/metadata"
)

type mockInterfaceListener struct {
	mu      sync.Mutex
	calls   int
	lastIf  string
	lastIdx int32
}

func (m *mockInterfaceListener) UpdateDefaultInterface(interfaceName string, interfaceIndex int32, isExpensive bool, isConstrained bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	m.lastIf = interfaceName
	m.lastIdx = interfaceIndex
}

func (m *mockInterfaceListener) UpdateNetworkPath(string) {}

type fakeRule string

func (r fakeRule) String() string                              { return string(r) }
func (r fakeRule) Type() string                                { return "fake" }
func (r fakeRule) Start() error                                { return nil }
func (r fakeRule) Close() error                                { return nil }
func (r fakeRule) Match(metadata *adapter.InboundContext) bool { return false }
func (r fakeRule) Action() adapter.RuleAction                  { return nil }

func TestUpdatePhysicalNetworkAndConcurrency(t *testing.T) {
	interfaces, err := nativeInterfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatal("no native interface available")
	}
	firstIf := interfaces[0]

	p := &harmonyPlatform{
		iface:        firstIf.Name,
		netID:        100,
		networkState: physicalNetworkState{Type: "wifi", SSID: "Home"},
	}

	// Invalid parameters must be rejected without mutating state.
	if err := p.updatePhysicalNetwork("", 101, physicalNetworkState{Type: "cellular"}); err == nil {
		t.Fatal("expected error for empty interface name")
	}
	if err := p.updatePhysicalNetwork(firstIf.Name, 0, physicalNetworkState{Type: "cellular"}); err == nil {
		t.Fatal("expected error for zero netID")
	}
	if err := p.updatePhysicalNetwork(firstIf.Name, -5, physicalNetworkState{Type: "cellular"}); err == nil {
		t.Fatal("expected error for negative netID")
	}
	if p.netID != 100 || p.iface != firstIf.Name || p.ReadWIFIState().SSID != "Home" {
		t.Fatal("invalid update mutated platform state")
	}

	listener := &mockInterfaceListener{}
	if err := p.StartDefaultInterfaceMonitor(listener); err != nil {
		t.Fatal(err)
	}

	// Valid update with real interface invokes listener callback.
	if err := p.updatePhysicalNetwork(firstIf.Name, 200, physicalNetworkState{Type: "cellular"}); err != nil {
		t.Fatal(err)
	}
	listener.mu.Lock()
	callsAfterReal := listener.calls
	lastIf := listener.lastIf
	lastIdx := listener.lastIdx
	listener.mu.Unlock()
	if callsAfterReal < 2 || lastIf != firstIf.Name || lastIdx != firstIf.Index {
		t.Fatalf("listener not updated properly: calls=%d lastIf=%s lastIdx=%d", callsAfterReal, lastIf, lastIdx)
	}
	if p.networkType() != libbox.InterfaceTypeCellular {
		t.Fatal("networkType not updated to cellular")
	}

	// Valid update with synthetic/non-existent interface must NOT panic and should skip listener callback.
	if err := p.updatePhysicalNetwork("rmnet_data99_nonexistent", 201, physicalNetworkState{Type: "wifi", SSID: "Office"}); err != nil {
		t.Fatal(err)
	}
	listener.mu.Lock()
	callsAfterMissing := listener.calls
	listener.mu.Unlock()
	if callsAfterMissing != callsAfterReal {
		t.Fatal("listener should be skipped when interface does not exist locally")
	}
	if p.ReadWIFIState().SSID != "Office" {
		t.Fatal("wifi SSID not updated")
	}

	// Concurrency / data race stress test.
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for j := 0; j < 40; j++ {
				if j%2 == 0 {
					_ = p.updatePhysicalNetwork(firstIf.Name, int32(300+worker*100+j), physicalNetworkState{Type: "wifi", SSID: "RaceNet"})
				} else {
					_ = p.updatePhysicalNetwork("rmnet_race", int32(300+worker*100+j), physicalNetworkState{Type: "cellular"})
				}
				_ = p.AutoDetectInterfaceControl(1)
				_, _ = p.GetInterfaces()
				_ = p.ReadWIFIState()
				_ = p.networkType()
			}
		}(i)
	}
	wg.Wait()
	_ = p.CloseDefaultInterfaceMonitor(listener)
}

func TestUpdatePhysicalNetControlAction(t *testing.T) {
	dir := t.TempDir()
	if err := libbox.Setup(&libbox.SetupOptions{BasePath: dir, WorkingPath: dir, TempPath: dir, LogMaxLines: 100, OomKillerDisabled: true}); err != nil {
		t.Fatal(err)
	}
	interfaces, err := nativeInterfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatal("no native interface")
	}
	p := &harmonyPlatform{
		iface:        interfaces[0].Name,
		netID:        100,
		networkState: physicalNetworkState{Type: "wifi", SSID: "InitWifi"},
	}
	server, err := libbox.NewCommandServer(&commandHandler{}, p)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = server.CloseService()
		server.Close()
		running = nil
		activePlatform = nil
	}()
	profile := `{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},"log":{"level":"warn","output":"/dev/null"}}`
	if err := server.StartOrReloadService(profile, &libbox.OverrideOptions{}); err != nil {
		t.Fatal(err)
	}
	running = server
	activePlatform = p

	call := func(input string) controlReply {
		t.Helper()
		var r controlReply
		if err := json.Unmarshal([]byte(coreControl(input)), &r); err != nil {
			t.Fatal(err)
		}
		return r
	}

	// Valid handover with network state.
	reply := call(`{"action":"update-physical-net","interfaceName":"` + interfaces[0].Name + `","netId":205,"network":{"type":"cellular","ssid":"stale"}}`)
	if !reply.OK || reply.Message != "物理网络已热切换" {
		t.Fatalf("unexpected reply: %+v", reply)
	}
	p.mu.RLock()
	gotNetID, gotIface := p.netID, p.iface
	p.mu.RUnlock()
	if gotNetID != 205 || gotIface != interfaces[0].Name {
		t.Fatalf("platform not updated: netID=%d iface=%s", gotNetID, gotIface)
	}
	if p.networkType() != libbox.InterfaceTypeCellular || p.ReadWIFIState().SSID != "" {
		t.Fatal("network state not updated to cellular")
	}

	// Valid handover without network field preserves existing networkState.
	reply = call(`{"action":"update-physical-net","interfaceName":"rmnet_sim0","netId":206}`)
	if !reply.OK || reply.Message != "物理网络已热切换" {
		t.Fatalf("handover without network failed: %+v", reply)
	}
	if p.networkType() != libbox.InterfaceTypeCellular {
		t.Fatal("handover without network overwrote existing networkState")
	}

	// Invalid parameters.
	if call(`{"action":"update-physical-net","interfaceName":"","netId":207}`).OK {
		t.Fatal("accepted empty interfaceName")
	}
	if call(`{"action":"update-physical-net","interfaceName":"wlan0","netId":0}`).OK {
		t.Fatal("accepted zero netId")
	}
	if call(`{"action":"update-physical-net","interfaceName":"wlan0","netId":-1}`).OK {
		t.Fatal("accepted negative netId")
	}
	if call(`{"action":"update-physical-net","interfaceName":"wlan0","netId":208,"network":{"type":"vpn"}}`).OK {
		t.Fatal("accepted invalid network type")
	}
	p.mu.RLock()
	stillNetID := p.netID
	p.mu.RUnlock()
	if stillNetID != 206 {
		t.Fatalf("invalid handover mutated netID to %d", stillNetID)
	}

	// Nil activePlatform must fail gracefully.
	activePlatform = nil
	if call(`{"action":"update-physical-net","interfaceName":"wlan0","netId":209}`).OK {
		t.Fatal("accepted handover when activePlatform is nil")
	}
}

func TestSnapshotRecentRequestsActiveAndClosed(t *testing.T) {
	// 1. Unit test collectRecentRequests: dedup, ordering, closed duration, truncation, 500 cap.
	now := time.Now()
	dupID := uuid.Must(uuid.NewV4())
	closedID := uuid.Must(uuid.NewV4())
	longRule := strings.Repeat("r", 600)
	longDomain := strings.Repeat("d", 300)

	activeMeta := &trafficcontrol.TrackerMetadata{
		ID: dupID,
		Metadata: adapter.InboundContext{
			Network:     "tcp",
			Source:      M.SocksaddrFrom(netip.MustParseAddr("10.0.0.1"), 12345),
			Destination: M.SocksaddrFrom(netip.MustParseAddr("1.1.1.1"), 443),
			Domain:      longDomain,
		},
		CreatedAt: now.Add(-2 * time.Second),
		Outbound:  "proxy",
		Rule:      fakeRule(longRule),
		Upload:    &atomic.Int64{},
		Download:  &atomic.Int64{},
	}
	activeMeta.Upload.Store(1024)
	activeMeta.Download.Store(2048)

	closedDupMeta := &trafficcontrol.TrackerMetadata{
		ID:        dupID,
		CreatedAt: now.Add(-2 * time.Second),
		ClosedAt:  now.Add(-1 * time.Second),
		Upload:    &atomic.Int64{},
		Download:  &atomic.Int64{},
	}
	closedMeta := &trafficcontrol.TrackerMetadata{
		ID: closedID,
		Metadata: adapter.InboundContext{
			Network:     "udp",
			Source:      M.SocksaddrFrom(netip.MustParseAddr("10.0.0.2"), 54321),
			Destination: M.SocksaddrFrom(netip.MustParseAddr("8.8.8.8"), 53),
			Domain:      "dns.google",
		},
		CreatedAt: now.Add(-5 * time.Second),
		ClosedAt:  now.Add(-4500 * time.Millisecond),
		Outbound:  "direct",
		Upload:    &atomic.Int64{},
		Download:  &atomic.Int64{},
	}

	recent := collectRecentRequests([]*trafficcontrol.TrackerMetadata{activeMeta}, []*trafficcontrol.TrackerMetadata{closedDupMeta, closedMeta})
	if len(recent) != 2 {
		t.Fatalf("expected 2 deduplicated requests, got %d", len(recent))
	}
	if recent[0].ID != dupID.String() || recent[0].Status != "active" {
		t.Fatalf("expected newest active request first, got %+v", recent[0])
	}
	if len(recent[0].Rule) > 512+len("…") || !strings.HasSuffix(recent[0].Rule, "…") {
		t.Fatalf("rule not truncated: len=%d", len(recent[0].Rule))
	}
	if len(recent[0].Domain) > 255+len("…") || !strings.HasSuffix(recent[0].Domain, "…") {
		t.Fatalf("domain not truncated: len=%d", len(recent[0].Domain))
	}
	if recent[1].ID != closedID.String() || recent[1].Status != "closed" || recent[1].ClosedAt == 0 || recent[1].DurationMs < 400 {
		t.Fatalf("expected closed request with duration, got %+v", recent[1])
	}

	// Verify 500 cap.
	many := make([]*trafficcontrol.TrackerMetadata, 550)
	for i := range many {
		many[i] = &trafficcontrol.TrackerMetadata{
			ID:        uuid.Must(uuid.NewV4()),
			CreatedAt: now.Add(-time.Duration(i) * time.Millisecond),
			Upload:    &atomic.Int64{},
			Download:  &atomic.Int64{},
		}
	}
	capped := collectRecentRequests(many, nil)
	if len(capped) != 500 {
		t.Fatalf("expected cap at 500, got %d", len(capped))
	}

	// 2. Integration test via real daemon TrafficManager + snapshot action.
	dir := t.TempDir()
	if err := libbox.Setup(&libbox.SetupOptions{BasePath: dir, WorkingPath: dir, TempPath: dir, LogMaxLines: 100, OomKillerDisabled: true}); err != nil {
		t.Fatal(err)
	}
	interfaces, err := nativeInterfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatal("no native interface")
	}
	p := &harmonyPlatform{iface: interfaces[0].Name, netID: 100}
	server, err := libbox.NewCommandServer(&commandHandler{}, p)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = server.CloseService()
		server.Close()
		running = nil
		activePlatform = nil
	}()
	profile := `{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},"log":{"level":"warn","output":"/dev/null"}}`
	if err := server.StartOrReloadService(profile, &libbox.OverrideOptions{}); err != nil {
		t.Fatal(err)
	}
	running = server
	activePlatform = p

	tm := server.Instance().TrafficManager()
	outbound, ok := server.Instance().Box().Outbound().Outbound("direct")
	if !ok {
		t.Fatal("direct outbound missing")
	}

	c1a, c1b := net.Pipe()
	defer c1a.Close()
	defer c1b.Close()
	trackedActive := tm.RoutedConnection(context.Background(), c1a, adapter.InboundContext{
		Network:     "tcp",
		Source:      M.SocksaddrFrom(netip.MustParseAddr("127.0.0.1"), 40001),
		Destination: M.SocksaddrFrom(netip.MustParseAddr("1.1.1.1"), 443),
		Domain:      "active.example.test",
	}, nil, outbound)
	defer trackedActive.Close()

	c2a, c2b := net.Pipe()
	defer c2b.Close()
	trackedClosed := tm.RoutedConnection(context.Background(), c2a, adapter.InboundContext{
		Network:     "tcp",
		Source:      M.SocksaddrFrom(netip.MustParseAddr("127.0.0.1"), 40002),
		Destination: M.SocksaddrFrom(netip.MustParseAddr("8.8.8.8"), 443),
		Domain:      "closed.example.test",
	}, nil, outbound)
	time.Sleep(5 * time.Millisecond)
	_ = trackedClosed.Close()

	var reply controlReply
	if err := json.Unmarshal([]byte(coreControl(`{"action":"snapshot"}`)), &reply); err != nil {
		t.Fatal(err)
	}
	if !reply.OK || reply.Data == nil {
		t.Fatalf("snapshot failed: %+v", reply)
	}
	if len(reply.Data.Connections) != 1 || reply.Data.Connections[0].Status != "active" || reply.Data.Connections[0].Domain != "active.example.test" {
		t.Fatalf("unexpected active connections: %+v", reply.Data.Connections)
	}
	if len(reply.Data.RecentRequests) != 2 {
		t.Fatalf("expected 2 recentRequests (active+closed), got %+v", reply.Data.RecentRequests)
	}
	var sawActive, sawClosed bool
	for _, req := range reply.Data.RecentRequests {
		if req.Domain == "active.example.test" && req.Status == "active" {
			sawActive = true
		}
		if req.Domain == "closed.example.test" && req.Status == "closed" && req.ClosedAt > 0 {
			sawClosed = true
		}
	}
	if !sawActive || !sawClosed {
		t.Fatalf("missing active or closed entry in recentRequests: %+v", reply.Data.RecentRequests)
	}
}

func TestDiagnoseHostControlAction(t *testing.T) {
	dir := t.TempDir()
	if err := libbox.Setup(&libbox.SetupOptions{BasePath: dir, WorkingPath: dir, TempPath: dir, LogMaxLines: 100, OomKillerDisabled: true}); err != nil {
		t.Fatal(err)
	}
	interfaces, err := nativeInterfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatal("no native interface")
	}
	p := &harmonyPlatform{iface: interfaces[0].Name, netID: 100}
	server, err := libbox.NewCommandServer(&commandHandler{}, p)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = server.CloseService()
		server.Close()
		running = nil
		activePlatform = nil
	}()
	profile := `{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"},"log":{"level":"warn","output":"/dev/null"}}`
	if err := server.StartOrReloadService(profile, &libbox.OverrideOptions{}); err != nil {
		t.Fatal(err)
	}
	running = server
	activePlatform = p

	call := func(input string) controlReply {
		t.Helper()
		var r controlReply
		if err := json.Unmarshal([]byte(coreControl(input)), &r); err != nil {
			t.Fatal(err)
		}
		return r
	}

	// IPv4 literal.
	r4 := call(`{"action":"diagnose-host","host":"1.1.1.1"}`)
	if !r4.OK || r4.Diagnosis == nil || r4.Diagnosis.Host != "1.1.1.1" || len(r4.Diagnosis.IPv4) != 1 || r4.Diagnosis.IPv4[0] != "1.1.1.1" || len(r4.Diagnosis.IPv6) != 0 || r4.Diagnosis.DNSError != "" {
		t.Fatalf("unexpected IPv4 diagnosis: %+v", r4)
	}

	// IPv6 literal.
	r6 := call(`{"action":"diagnose-host","host":"2606:4700:4700::1111"}`)
	if !r6.OK || r6.Diagnosis == nil || len(r6.Diagnosis.IPv6) != 1 || r6.Diagnosis.IPv6[0] != "2606:4700:4700::1111" || len(r6.Diagnosis.IPv4) != 0 {
		t.Fatalf("unexpected IPv6 diagnosis: %+v", r6)
	}

	// Invalid host inputs.
	invalidHosts := []string{
		"",
		"example .com",
		" 1.1.1.1",
		"1.1.1.1\n",
		"host\tname",
		strings.Repeat("a", 254),
	}
	for _, bad := range invalidHosts {
		payload, _ := json.Marshal(controlRequest{Action: "diagnose-host", Host: bad})
		r := call(string(payload))
		if r.OK || r.Diagnosis != nil {
			t.Fatalf("accepted invalid host %q: %+v", bad, r)
		}
	}

	// Localhost domain resolution via router / fallback.
	rLocal := call(`{"action":"diagnose-host","host":"localhost"}`)
	if !rLocal.OK || rLocal.Diagnosis == nil || rLocal.Diagnosis.Host != "localhost" || rLocal.Diagnosis.Summary == "" {
		t.Fatalf("unexpected localhost diagnosis: %+v", rLocal)
	}
}
