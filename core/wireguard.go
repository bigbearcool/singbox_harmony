package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"strings"
	"time"

	M "github.com/sagernet/sing/common/metadata"
)

type wireGuardPeer struct {
	Index          int   `json:"index"`
	LastHandshake  int64 `json:"lastHandshake"`
	TxBytes        int64 `json:"txBytes"`
	RxBytes        int64 `json:"rxBytes"`
	EndpointFamily int   `json:"endpointFamily"`
}
type wireGuardProbe struct {
	UpdatedAt int64  `json:"updatedAt"`
	OK        bool   `json:"ok"`
	Summary   string `json:"summary"`
	Category  string `json:"category"`
	DNSReply  bool   `json:"dnsReply"`
	RCode     int    `json:"rcode"`
}
type wireGuardView struct {
	Tag           string          `json:"tag"`
	Available     bool            `json:"available"`
	Active        bool            `json:"active"`
	Transport     string          `json:"transport"`
	Peers         []wireGuardPeer `json:"peers"`
	DNSConfigured bool            `json:"dnsConfigured"`
	DNSCovered    bool            `json:"dnsCovered"`
	IPv4          bool            `json:"ipv4"`
	IPv6          bool            `json:"ipv6"`
	LastProbe     *wireGuardProbe `json:"lastProbe,omitempty"`
}
type wireGuardTarget struct {
	tag     string
	dns     netip.AddrPort
	allowed []netip.Prefix
}

var wireGuardTargets []wireGuardTarget
var wireGuardProbes = map[string]wireGuardProbe{}

func configureWireGuardDiagnostics(input string) {
	var config struct {
		Endpoints []struct {
			Type  string `json:"type"`
			Tag   string `json:"tag"`
			Peers []struct {
				AllowedIPs []string `json:"allowed_ips"`
			} `json:"peers"`
		} `json:"endpoints"`
		DNS struct {
			Servers []struct {
				Type   string `json:"type"`
				Server string `json:"server"`
				Port   uint16 `json:"server_port"`
				Detour string `json:"detour"`
			} `json:"servers"`
		} `json:"dns"`
	}
	wireGuardTargets = nil
	wireGuardProbes = map[string]wireGuardProbe{}
	if json.Unmarshal([]byte(input), &config) != nil {
		return
	}
	for _, endpoint := range config.Endpoints {
		if endpoint.Type != "wireguard" {
			continue
		}
		target := wireGuardTarget{tag: endpoint.Tag}
		for _, peer := range endpoint.Peers {
			for _, value := range peer.AllowedIPs {
				if prefix, err := netip.ParsePrefix(value); err == nil {
					target.allowed = append(target.allowed, prefix)
				}
			}
		}
		for _, server := range config.DNS.Servers {
			if server.Type != "udp" || server.Detour != endpoint.Tag {
				continue
			}
			address, err := netip.ParseAddr(server.Server)
			if err != nil {
				continue
			}
			port := server.Port
			if port == 0 {
				port = 53
			}
			target.dns = netip.AddrPortFrom(address, port)
			break
		}
		wireGuardTargets = append(wireGuardTargets, target)
	}
}
func (t wireGuardTarget) covers(address netip.Addr) bool {
	for _, prefix := range t.allowed {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}
func wireGuardViews() []wireGuardView {
	result := make([]wireGuardView, 0, len(wireGuardTargets))
	if running == nil || running.Instance() == nil {
		return result
	}
	for _, target := range wireGuardTargets {
		view := wireGuardView{Tag: target.tag, Peers: []wireGuardPeer{}, DNSConfigured: target.dns.IsValid(), DNSCovered: target.dns.IsValid() && target.covers(target.dns.Addr())}
		for _, prefix := range target.allowed {
			if prefix.Addr().Is4() {
				view.IPv4 = true
			} else {
				view.IPv6 = true
			}
		}
		if endpoint, ok := running.Instance().Box().Endpoint().Get(target.tag); ok {
			if source, ok := endpoint.(interface{ HarmonyWireGuardStatus() string }); ok {
				var data struct {
					Active    bool            `json:"active"`
					Transport string          `json:"transport"`
					Peers     []wireGuardPeer `json:"peers"`
				}
				if json.Unmarshal([]byte(source.HarmonyWireGuardStatus()), &data) == nil {
					view.Available = true
					view.Active = data.Active
					view.Transport = data.Transport
					if data.Peers != nil {
						view.Peers = data.Peers
					}
				}
			}
		}
		if last, ok := wireGuardProbes[target.tag]; ok {
			copy := last
			view.LastProbe = &copy
		}
		result = append(result, view)
	}
	return result
}
func wireGuardHasHandshake(tag string) bool {
	for _, view := range wireGuardViews() {
		if view.Tag == tag {
			for _, peer := range view.Peers {
				if peer.LastHandshake > 0 {
					return true
				}
			}
		}
	}
	return false
}
func wireGuardFailure(err error, handshake bool) (string, string) {
	message := strings.ToLower(err.Error())
	if strings.Contains(message, "permission denied") || strings.Contains(message, "operation not permitted") {
		return "socket-permission", "外层 UDP 被系统权限拒绝"
	}
	if strings.Contains(message, "绑定物理网络失败") {
		return "socket-binding", "外层 UDP 绑定物理网络失败"
	}
	if strings.Contains(message, "no such host") {
		return "peer-resolution", "WireGuard peer 域名解析失败"
	}
	if strings.Contains(message, "network is unreachable") || strings.Contains(message, "no route") {
		return "no-route", "当前网络没有到 peer 的可用路由"
	}
	var timeout net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &timeout) && timeout.Timeout()) {
		if handshake {
			return "inner-timeout", "已有握手记录，本次家庭 DNS 未在时限内回包"
		}
		return "no-handshake", "本次未取得握手和家庭 DNS 回包，请复测外层 UDP 与 peer"
	}
	return "transport-error", "WireGuard 传输未完成，请查看握手与收发计数"
}
func probeWireGuard(ctx context.Context, tag string) wireGuardProbe {
	result := wireGuardProbe{UpdatedAt: time.Now().UnixMilli(), Category: "unavailable", Summary: "未找到对应的 WireGuard 通道"}
	defer func() { wireGuardProbes[tag] = result }()
	var target *wireGuardTarget
	for i := range wireGuardTargets {
		if wireGuardTargets[i].tag == tag {
			target = &wireGuardTargets[i]
			break
		}
	}
	if target == nil || running == nil || running.Instance() == nil {
		return result
	}
	if !target.dns.IsValid() {
		result.Category = "no-dns-target"
		result.Summary = "未配置通过该通道访问的 UDP DNS，仍可查看握手计数"
		return result
	}
	if !target.covers(target.dns.Addr()) {
		result.Category = "dns-outside-allowed-ips"
		result.Summary = "家庭 DNS 不在 peer 的 AllowedIPs 中"
		return result
	}
	endpoint, ok := running.Instance().Box().Endpoint().Get(tag)
	if !ok {
		return result
	}
	conn, err := endpoint.DialContext(ctx, "udp", M.SocksaddrFromNetIP(target.dns))
	if err == nil {
		defer conn.Close()
		deadline, ok := ctx.Deadline()
		if !ok {
			deadline = time.Now().Add(4 * time.Second)
		}
		_ = conn.SetDeadline(deadline)
		// A bounded A query exercises authenticated WG traffic to the explicitly
		// configured home resolver. It bypasses the TUN/DNS hijack shortcut.
		request := []byte{0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, 111, 110, 101, 3, 111, 110, 101, 3, 111, 110, 101, 3, 111, 110, 101, 0, 0, 1, 0, 1}
		_, err = rand.Read(request[:2])
		if err == nil {
			var n int
			n, err = conn.Write(request)
			if err == nil && n != len(request) {
				err = io.ErrShortWrite
			}
		}
		if err == nil {
			reply := make([]byte, 4096)
			var n int
			n, err = conn.Read(reply)
			if err == nil {
				if n >= 12 && reply[0] == request[0] && reply[1] == request[1] && reply[2]&0x80 != 0 {
					result.OK = true
					result.Category = "dns-reply"
					result.DNSReply = true
					result.RCode = int(reply[3] & 15)
					result.Summary = "加密通道与家庭 DNS 回包已确认"
					return result
				}
				err = errors.New("unexpected DNS response")
			}
		}
	}
	result.Category, result.Summary = wireGuardFailure(err, wireGuardHasHandshake(tag))
	return result
}
