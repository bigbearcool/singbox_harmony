package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"

	mDNS "github.com/miekg/dns"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	"github.com/sagernet/sing-box/daemon"
	"github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

type controlRequest struct {
	Action        string                `json:"action"`
	Group         string                `json:"group"`
	Outbound      string                `json:"outbound"`
	ID            string                `json:"id"`
	Mode          string                `json:"mode"`
	Network       *physicalNetworkState `json:"network,omitempty"`
	InterfaceName string                `json:"interfaceName,omitempty"`
	NetID         int32                 `json:"netId,omitempty"`
	Host          string                `json:"host,omitempty"`
	Content       string                `json:"content,omitempty"`
}

type groupSnapshot struct {
	grpc.ServerStream
	ctx    context.Context
	groups []*daemon.Group
}

func (s *groupSnapshot) Context() context.Context        { return s.ctx }
func (s *groupSnapshot) Send(value *daemon.Groups) error { s.groups = value.Group; return io.EOF }

type connectionView struct {
	ID          string `json:"id"`
	Network     string `json:"network"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Domain      string `json:"domain"`
	Outbound    string `json:"outbound"`
	Rule        string `json:"rule"`
	Upload      int64  `json:"upload"`
	Download    int64  `json:"download"`
	CreatedAt   int64  `json:"createdAt"`
	Status      string `json:"status,omitempty"`
	ClosedAt    int64  `json:"closedAt,omitempty"`
	DurationMs  int64  `json:"durationMs,omitempty"`
}
type dashboardSnapshot struct {
	Groups         []*daemon.Group  `json:"groups"`
	Connections    []connectionView `json:"connections"`
	RecentRequests []connectionView `json:"recentRequests,omitempty"`
	Logs           []string         `json:"logs"`
	Modes          []string         `json:"modes"`
	Mode           string           `json:"mode"`
	WireGuard      []wireGuardView  `json:"wireGuard"`
	Tunnels        []tunnelView     `json:"tunnels,omitempty"`
}
type diagnoseResult struct {
	Host      string   `json:"host"`
	IPv4      []string `json:"ipv4"`
	IPv6      []string `json:"ipv6"`
	DNSError  string   `json:"dnsError,omitempty"`
	LatencyMs int64    `json:"latencyMs"`
	Mode      string   `json:"mode,omitempty"`
	Summary   string   `json:"summary"`
}
type controlReply struct {
	OK        bool               `json:"ok"`
	Message   string             `json:"message"`
	Data      *dashboardSnapshot `json:"data,omitempty"`
	Diagnosis *diagnoseResult    `json:"diagnosis,omitempty"`
	Converted string             `json:"converted,omitempty"`
	DeepProbe *deepProbeResult   `json:"deepProbe,omitempty"`
}

var logURL = regexp.MustCompile(`https?://[^\s]+`)
var logSecret = regexp.MustCompile(`(?i)(password|private_key|token|authorization|uuid)["\s]*[:=]["\s]*[^\s,}"']+`)
var logIPv4 = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}\b`)
var logIPv6 = regexp.MustCompile(`\[[0-9a-fA-F:]+\]`)
var activeLogRedactions []string

func logRedactions(config string) []string {
	var root any
	if json.Unmarshal([]byte(config), &root) != nil {
		return nil
	}
	values := map[string]bool{}
	var walk func(any)
	walk = func(value any) {
		switch item := value.(type) {
		case map[string]any:
			for key, child := range item {
				switch key {
				case "wifi_ssid", "wifi_bssid":
					if text, ok := child.(string); ok && text != "" {
						values[text] = true
					}
					if list, ok := child.([]any); ok {
						for _, value := range list {
							if text, ok := value.(string); ok && text != "" {
								values[text] = true
							}
						}
					}
				case "server", "server_name", "address", "uuid", "password", "private_key", "public_key", "pre_shared_key", "short_id":
					if text, ok := child.(string); ok && len(text) > 3 {
						values[text] = true
					}
				}
				walk(child)
			}
		case []any:
			for _, child := range item {
				walk(child)
			}
		}
	}
	walk(root)
	var result []string
	for value := range values {
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return len(result[i]) > len(result[j]) })
	return result
}

func safeLog(value string) string {
	for _, secret := range activeLogRedactions {
		value = strings.ReplaceAll(value, secret, "[配置值]")
	}
	value = logURL.ReplaceAllString(value, "[URL]")
	value = logSecret.ReplaceAllString(value, "$1=[redacted]")
	value = logIPv4.ReplaceAllString(value, "[IP]")
	value = logIPv6.ReplaceAllString(value, "[IPv6]")
	if len(value) > 2048 {
		value = value[:2048]
	}
	return value
}

func buildConnectionView(conn *trafficcontrol.TrackerMetadata, status string) connectionView {
	rule := ""
	if conn.Rule != nil {
		rule = conn.Rule.String()
		if len(rule) > 512 {
			rule = rule[:512] + "…"
		}
	}
	domain := conn.Metadata.Domain
	if len(domain) > 255 {
		domain = domain[:255] + "…"
	}
	view := connectionView{
		ID:          conn.ID.String(),
		Network:     conn.Metadata.Network,
		Source:      conn.Metadata.Source.String(),
		Destination: conn.Metadata.Destination.String(),
		Domain:      domain,
		Outbound:    conn.Outbound,
		Rule:        rule,
		Upload:      conn.Upload.Load(),
		Download:    conn.Download.Load(),
		CreatedAt:   conn.CreatedAt.UnixMilli(),
		Status:      status,
	}
	if status == "closed" && !conn.ClosedAt.IsZero() {
		view.ClosedAt = conn.ClosedAt.UnixMilli()
		duration := conn.ClosedAt.Sub(conn.CreatedAt).Milliseconds()
		if duration < 0 {
			duration = 0
		}
		view.DurationMs = duration
	}
	return view
}

type recentRequestItem struct {
	createdAt time.Time
	view      connectionView
}

func collectRecentRequests(active, closed []*trafficcontrol.TrackerMetadata) []connectionView {
	seen := make(map[string]bool, len(active)+len(closed))
	items := make([]recentRequestItem, 0, len(active)+len(closed))
	for _, conn := range active {
		if conn == nil {
			continue
		}
		id := conn.ID.String()
		if seen[id] {
			continue
		}
		seen[id] = true
		items = append(items, recentRequestItem{
			createdAt: conn.CreatedAt,
			view:      buildConnectionView(conn, "active"),
		})
	}
	for _, conn := range closed {
		if conn == nil {
			continue
		}
		id := conn.ID.String()
		if seen[id] {
			continue
		}
		seen[id] = true
		items = append(items, recentRequestItem{
			createdAt: conn.CreatedAt,
			view:      buildConnectionView(conn, "closed"),
		})
	}
	sort.Slice(items, func(i, j int) bool {
		return items[i].createdAt.After(items[j].createdAt)
	})
	if len(items) > 500 {
		items = items[:500]
	}
	result := make([]connectionView, len(items))
	for i, item := range items {
		result[i] = item.view
	}
	return result
}

type diagnosePacketWriter struct {
	ch chan []byte
}

func (w *diagnosePacketWriter) WritePacket(buffer *buf.Buffer, _ M.Socksaddr) error {
	defer buffer.Release()
	data := append([]byte(nil), buffer.Bytes()...)
	select {
	case w.ch <- data:
	default:
	}
	return nil
}

func lookupViaRouterDNS(ctx context.Context, router adapter.Router, host string, qtype uint16) ([]netip.Addr, error) {
	msg := new(mDNS.Msg)
	msg.SetQuestion(mDNS.Fqdn(host), qtype)
	msg.RecursionDesired = true
	payload, err := msg.Pack()
	if err != nil {
		return nil, err
	}
	writer := &diagnosePacketWriter{ch: make(chan []byte, 1)}
	router.HijackDNSPacket(ctx, payload, writer, adapter.InboundContext{
		Inbound:     "diagnose",
		InboundType: "internal",
		Network:     "udp",
	})
	select {
	case raw := <-writer.ch:
		var resp mDNS.Msg
		if err := resp.Unpack(raw); err != nil {
			return nil, err
		}
		if resp.Rcode != mDNS.RcodeSuccess {
			code := mDNS.RcodeToString[resp.Rcode]
			if code == "" {
				code = fmt.Sprintf("RCODE_%d", resp.Rcode)
			}
			return nil, errors.New(code)
		}
		var addrs []netip.Addr
		for _, ans := range resp.Answer {
			switch rr := ans.(type) {
			case *mDNS.A:
				if addr, ok := netip.AddrFromSlice(rr.A); ok {
					addrs = append(addrs, addr.Unmap())
				}
			case *mDNS.AAAA:
				if addr, ok := netip.AddrFromSlice(rr.AAAA); ok {
					addrs = append(addrs, addr)
				}
			}
		}
		return addrs, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func diagnoseHost(ctx context.Context, host string) (*diagnoseResult, error) {
	if host == "" || len(host) > 253 || strings.ContainsFunc(host, unicode.IsSpace) {
		return nil, errors.New("主机名无效")
	}
	start := time.Now()
	mode := ""
	if running != nil {
		if status, e := running.GetClashModeStatus(ctx, &emptypb.Empty{}); e == nil && status != nil {
			mode = status.CurrentMode
		}
	}
	result := &diagnoseResult{
		Host: host,
		IPv4: []string{},
		IPv6: []string{},
		Mode: mode,
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		addr = addr.Unmap()
		if addr.Is4() {
			result.IPv4 = append(result.IPv4, addr.String())
			result.Summary = "IPv4 地址，无需 DNS 解析"
		} else {
			result.IPv6 = append(result.IPv6, addr.String())
			result.Summary = "IPv6 地址，无需 DNS 解析"
		}
		result.LatencyMs = time.Since(start).Milliseconds()
		return result, nil
	}

	v4Set := map[string]bool{}
	v6Set := map[string]bool{}
	addAddr := func(addr netip.Addr) {
		addr = addr.Unmap()
		if addr.Is4() {
			v4Set[addr.String()] = true
		} else if addr.Is6() {
			v6Set[addr.String()] = true
		}
	}

	var dnsErr error
	usedRouter := false
	if running != nil {
		if instance := running.Instance(); instance != nil && instance.Box() != nil && instance.Box().Router() != nil {
			usedRouter = true
			router := instance.Box().Router()
			routerCtx, routerCancel := context.WithTimeout(ctx, 1500*time.Millisecond)
			var wg sync.WaitGroup
			var aAddrs, aaaaAddrs []netip.Addr
			var aErr, aaaaErr error
			wg.Add(2)
			go func() {
				defer wg.Done()
				aAddrs, aErr = lookupViaRouterDNS(routerCtx, router, host, mDNS.TypeA)
			}()
			go func() {
				defer wg.Done()
				aaaaAddrs, aaaaErr = lookupViaRouterDNS(routerCtx, router, host, mDNS.TypeAAAA)
			}()
			wg.Wait()
			routerCancel()
			for _, addr := range aAddrs {
				addAddr(addr)
			}
			for _, addr := range aaaaAddrs {
				addAddr(addr)
			}
			if aErr != nil && aaaaErr != nil {
				dnsErr = aErr
			}
		}
	}
	if len(v4Set) == 0 && len(v6Set) == 0 && (!usedRouter || dnsErr != nil) {
		if ips, err := net.DefaultResolver.LookupIPAddr(ctx, host); err == nil {
			dnsErr = nil
			for _, ip := range ips {
				if addr, ok := netip.AddrFromSlice(ip.IP); ok {
					addAddr(addr)
				}
			}
		} else if dnsErr == nil {
			dnsErr = err
		}
	}

	for ip := range v4Set {
		result.IPv4 = append(result.IPv4, ip)
	}
	for ip := range v6Set {
		result.IPv6 = append(result.IPv6, ip)
	}
	sort.Strings(result.IPv4)
	sort.Strings(result.IPv6)
	result.LatencyMs = time.Since(start).Milliseconds()

	if len(result.IPv4) > 0 || len(result.IPv6) > 0 {
		result.Summary = fmt.Sprintf("解析成功：IPv4 %d 条，IPv6 %d 条（%dms）", len(result.IPv4), len(result.IPv6), result.LatencyMs)
	} else if dnsErr != nil {
		result.DNSError = dnsErr.Error()
		result.Summary = "DNS 解析失败：" + result.DNSError
	} else {
		result.Summary = "未解析到可用 IP 记录"
	}
	return result, nil
}

// Calls stay inside the VPN process. No TCP/Unix control listener is opened.
func coreControl(input string) string {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	reply := controlReply{Message: "内核操作失败"}
	var request controlRequest
	if err := json.Unmarshal([]byte(input), &request); err != nil {
		reply.Message = "VPN 未运行或请求无效"
	} else if request.Action == "convert-profile" {
		converted, count, convErr := convertSubscriptionWithCount(request.Content)
		if convErr != nil {
			reply.Message = convErr.Error()
		} else {
			reply.OK = true
			reply.Message = fmt.Sprintf("已转换 %d 个节点", count)
			reply.Converted = converted
		}
	} else if running == nil {
		reply.Message = "VPN 未运行或请求无效"
	} else {
		timeout := 2 * time.Second
		if request.Action == "wg-probe" || request.Action == "deep-probe" {
			timeout = 4 * time.Second
		} else if request.Action == "diagnose-host" {
			timeout = 3 * time.Second
		}
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		var err error
		switch request.Action {
		case "wifi-state":
			if request.Network == nil || activePlatform == nil {
				err = errors.New("网络状态不可用")
				break
			}
			encoded, _ := json.Marshal(request.Network)
			var state physicalNetworkState
			state, err = parsePhysicalNetworkState(string(encoded))
			if err == nil && activePlatform.setNetworkState(state) {
				running.UpdateWIFIState()
			}
		case "update-physical-net":
			if activePlatform == nil || request.NetID <= 0 || request.InterfaceName == "" {
				err = errors.New("物理网络参数无效")
				break
			}
			var state physicalNetworkState
			if request.Network != nil {
				encoded, _ := json.Marshal(request.Network)
				state, err = parsePhysicalNetworkState(string(encoded))
				if err != nil {
					break
				}
			}
			err = activePlatform.updatePhysicalNetwork(request.InterfaceName, request.NetID, state)
			if err == nil {
				running.UpdateWIFIState()
				running.ResetNetwork()
				reply.Message = "物理网络已热切换"
			}
		case "snapshot":
			data := &dashboardSnapshot{Groups: []*daemon.Group{}, Connections: []connectionView{}, RecentRequests: []connectionView{}, Logs: []string{}, Modes: []string{}}
			data.WireGuard = wireGuardViews()
			data.Tunnels = tunnelViews(running.Instance())
			groups := &groupSnapshot{ctx: ctx}
			_ = running.SubscribeGroups(&emptypb.Empty{}, groups)
			if groups.groups != nil {
				data.Groups = groups.groups
			}
			logs := &logSnapshot{}
			_ = running.SubscribeLog(&emptypb.Empty{}, logs)
			for _, line := range logs.entries {
				data.Logs = append(data.Logs, safeLog(line.Message))
			}
			if mode, e := running.GetClashModeStatus(ctx, &emptypb.Empty{}); e == nil {
				data.Modes = mode.ModeList
				data.Mode = mode.CurrentMode
			}
			if instance := running.Instance(); instance != nil && instance.TrafficManager() != nil {
				manager := instance.TrafficManager()
				activeConnections := manager.Connections()
				closedConnections := manager.ClosedConnections()
				data.RecentRequests = collectRecentRequests(activeConnections, closedConnections)
				connections := append([]*trafficcontrol.TrackerMetadata(nil), activeConnections...)
				sort.Slice(connections, func(i, j int) bool { return connections[i].CreatedAt.After(connections[j].CreatedAt) })
				if len(connections) > 200 {
					connections = connections[:200]
				}
				for _, conn := range connections {
					data.Connections = append(data.Connections, buildConnectionView(conn, "active"))
				}
			}
			reply.Data = data
		case "diagnose-host":
			var diagnosis *diagnoseResult
			diagnosis, err = diagnoseHost(ctx, request.Host)
			if err == nil {
				reply.Diagnosis = diagnosis
				reply.Message = diagnosis.Summary
			}
		case "select":
			_, err = running.SelectOutbound(ctx, &daemon.SelectOutboundRequest{GroupTag: request.Group, OutboundTag: request.Outbound})
			if err == nil && selectionStatePath != "" {
				if saveSelection(request.Group, request.Outbound) != nil {
					reply.Message = "已切换节点，但选择未能保存"
				}
			}
		case "urltest":
			_, err = running.URLTest(ctx, &daemon.URLTestRequest{OutboundTag: request.Outbound})
		case "wg-probe":
			probe := probeWireGuard(ctx, request.Outbound)
			reply.Message = probe.Summary
		case "deep-probe":
			probe := runDeepProbe(ctx)
			reply.DeepProbe = &probe
			reply.Message = probe.Summary
		case "close":
			_, err = running.CloseConnection(ctx, &daemon.CloseConnectionRequest{Id: request.ID})
		case "close-all":
			_, err = running.CloseAllConnections(ctx, &emptypb.Empty{})
		case "clear-logs":
			_, err = running.ClearLogs(ctx, &emptypb.Empty{})
		case "reset-network":
			running.ResetNetwork()
		case "mode":
			var modes *daemon.ClashModeStatus
			modes, err = running.GetClashModeStatus(ctx, &emptypb.Empty{})
			valid := false
			if err == nil {
				for _, mode := range modes.ModeList {
					if mode == request.Mode {
						valid = true
						break
					}
				}
			}
			if !valid {
				err = errors.New("mode unavailable")
			} else {
				_, err = running.SetClashMode(ctx, &daemon.ClashMode{Mode: request.Mode})
			}
		default:
			err = errors.New("unknown action")
		}
		if err == nil {
			reply.OK = true
			if reply.Message == "内核操作失败" {
				reply.Message = "操作完成"
			}
		}
	}
	data, _ := json.Marshal(reply)
	return string(data)
}
