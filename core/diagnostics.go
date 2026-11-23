package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/daemon"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	stunMagicCookie          uint32 = 0x2112A442
	stunBindingRequestType   uint16 = 0x0001
	stunBindingSuccessType   uint16 = 0x0101
	stunAttrMappedAddress    uint16 = 0x0001
	stunAttrXorMappedAddress uint16 = 0x0020
	stunHeaderSize                  = 20
)

type deepProbeResult struct {
	DirectIP      string `json:"directIp,omitempty"`
	DirectLatency int64  `json:"directLatencyMs,omitempty"`
	ProxyIP       string `json:"proxyIp,omitempty"`
	ProxyLatency  int64  `json:"proxyLatencyMs,omitempty"`
	NatType       string `json:"natType"`
	StunMapped    string `json:"stunMapped,omitempty"`
	Summary       string `json:"summary"`
}

type tunnelView struct {
	Tag     string `json:"tag"`
	Type    string `json:"type"`
	Active  bool   `json:"active"`
	Summary string `json:"summary"`
}

func buildStunBindingRequest(txID []byte) ([]byte, error) {
	if txID == nil {
		txID = make([]byte, 12)
		if _, err := rand.Read(txID); err != nil {
			return nil, err
		}
	} else if len(txID) != 12 {
		return nil, errors.New("invalid STUN transaction ID length")
	}
	pkt := make([]byte, stunHeaderSize)
	binary.BigEndian.PutUint16(pkt[0:2], stunBindingRequestType)
	binary.BigEndian.PutUint16(pkt[2:4], 0)
	binary.BigEndian.PutUint32(pkt[4:8], stunMagicCookie)
	copy(pkt[8:20], txID)
	return pkt, nil
}

func parseStunBindingResponse(packet []byte, expectedTxID []byte) (netip.AddrPort, error) {
	if len(packet) < stunHeaderSize {
		return netip.AddrPort{}, errors.New("STUN response too short")
	}
	msgType := binary.BigEndian.Uint16(packet[0:2])
	if msgType != stunBindingSuccessType {
		return netip.AddrPort{}, fmt.Errorf("unexpected STUN message type: 0x%04x", msgType)
	}
	msgLen := int(binary.BigEndian.Uint16(packet[2:4]))
	if stunHeaderSize+msgLen > len(packet) {
		return netip.AddrPort{}, errors.New("STUN response truncated")
	}
	if binary.BigEndian.Uint32(packet[4:8]) != stunMagicCookie {
		return netip.AddrPort{}, errors.New("invalid STUN magic cookie")
	}
	txID := packet[8:20]
	if len(expectedTxID) == 12 && !bytes.Equal(txID, expectedTxID) {
		return netip.AddrPort{}, errors.New("STUN transaction ID mismatch")
	}

	var fallbackMapped netip.AddrPort
	offset := stunHeaderSize
	end := stunHeaderSize + msgLen
	for offset+4 <= end {
		attrType := binary.BigEndian.Uint16(packet[offset : offset+2])
		attrLen := int(binary.BigEndian.Uint16(packet[offset+2 : offset+4]))
		offset += 4
		if offset+attrLen > end {
			return netip.AddrPort{}, errors.New("STUN attribute truncated")
		}
		val := packet[offset : offset+attrLen]
		switch attrType {
		case stunAttrXorMappedAddress:
			if ap, ok := decodeStunAddress(val, true, txID); ok {
				return ap, nil
			}
		case stunAttrMappedAddress:
			if ap, ok := decodeStunAddress(val, false, txID); ok && !fallbackMapped.IsValid() {
				fallbackMapped = ap
			}
		}
		padded := (attrLen + 3) &^ 3
		offset += padded
	}
	if fallbackMapped.IsValid() {
		return fallbackMapped, nil
	}
	return netip.AddrPort{}, errors.New("no mapped address in STUN response")
}

func decodeStunAddress(val []byte, xor bool, txID []byte) (netip.AddrPort, bool) {
	if len(val) < 4 {
		return netip.AddrPort{}, false
	}
	family := val[1]
	port := binary.BigEndian.Uint16(val[2:4])
	if xor {
		port ^= uint16(stunMagicCookie >> 16)
	}
	switch family {
	case 0x01: // IPv4
		if len(val) < 8 {
			return netip.AddrPort{}, false
		}
		var ip [4]byte
		copy(ip[:], val[4:8])
		if xor {
			var cookie [4]byte
			binary.BigEndian.PutUint32(cookie[:], stunMagicCookie)
			for i := 0; i < 4; i++ {
				ip[i] ^= cookie[i]
			}
		}
		return netip.AddrPortFrom(netip.AddrFrom4(ip), port), true
	case 0x02: // IPv6
		if len(val) < 20 || len(txID) != 12 {
			return netip.AddrPort{}, false
		}
		var ip [16]byte
		copy(ip[:], val[4:20])
		if xor {
			var mask [16]byte
			binary.BigEndian.PutUint32(mask[0:4], stunMagicCookie)
			copy(mask[4:16], txID)
			for i := 0; i < 16; i++ {
				ip[i] ^= mask[i]
			}
		}
		return netip.AddrPortFrom(netip.AddrFrom16(ip), port), true
	default:
		return netip.AddrPort{}, false
	}
}

func probeStunServer(ctx context.Context, server string) (netip.AddrPort, error) {
	stunCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	dialer := net.Dialer{Timeout: 2 * time.Second}
	conn, err := dialer.DialContext(stunCtx, "udp", server)
	if err != nil {
		return netip.AddrPort{}, err
	}
	defer conn.Close()
	if deadline, ok := stunCtx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	}
	req, err := buildStunBindingRequest(nil)
	if err != nil {
		return netip.AddrPort{}, err
	}
	txID := req[8:20]
	if _, err := conn.Write(req); err != nil {
		return netip.AddrPort{}, err
	}
	buf := make([]byte, 1500)
	n, err := conn.Read(buf)
	if err != nil {
		return netip.AddrPort{}, err
	}
	return parseStunBindingResponse(buf[:n], txID)
}

func extractTraceIP(body []byte) string {
	scanner := bufio.NewScanner(bytes.NewReader(body))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "ip=") {
			ip := strings.TrimSpace(strings.TrimPrefix(line, "ip="))
			if addr, err := netip.ParseAddr(ip); err == nil {
				return addr.String()
			}
		}
	}
	return ""
}

func probeDirectConnectivity(ctx context.Context) (string, int64) {
	directCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	start := time.Now()
	client := &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{
			Proxy: nil,
			DialContext: (&net.Dialer{
				Timeout: 1500 * time.Millisecond,
			}).DialContext,
		},
	}
	req, err := http.NewRequestWithContext(directCtx, http.MethodGet, "http://1.1.1.1/cdn-cgi/trace", nil)
	if err == nil {
		resp, err := client.Do(req)
		if err == nil {
			defer resp.Body.Close()
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			latency := time.Since(start).Milliseconds()
			if latency <= 0 {
				latency = 1
			}
			return extractTraceIP(body), latency
		}
	}
	// Lightweight TCP fallback if HTTP trace is unreachable.
	start = time.Now()
	conn, err := (&net.Dialer{Timeout: 1200 * time.Millisecond}).DialContext(directCtx, "tcp", "223.5.5.5:443")
	if err == nil {
		_ = conn.Close()
		latency := time.Since(start).Milliseconds()
		if latency <= 0 {
			latency = 1
		}
		return "", latency
	}
	return "", 0
}

func probeProxyConnectivity(ctx context.Context) (string, int64) {
	if running == nil {
		return "", 0
	}
	instance := running.Instance()
	if instance == nil || instance.Box() == nil || instance.Box().Outbound() == nil {
		return "", 0
	}
	outbound := instance.Box().Outbound().Default()
	if outbound == nil {
		return "", 0
	}
	proxyCtx, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
	defer cancel()
	start := time.Now()
	conn, err := outbound.DialContext(proxyCtx, "tcp", M.ParseSocksaddr("1.1.1.1:80"))
	if err != nil {
		return "", 0
	}
	defer conn.Close()
	if deadline, ok := proxyCtx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	connectLatency := time.Since(start).Milliseconds()
	if connectLatency <= 0 {
		connectLatency = 1
	}
	_, err = io.WriteString(conn, "GET /cdn-cgi/trace HTTP/1.1\r\nHost: 1.1.1.1\r\nConnection: close\r\n\r\n")
	if err != nil {
		return "", connectLatency
	}
	raw, _ := io.ReadAll(io.LimitReader(conn, 4096))
	totalLatency := time.Since(start).Milliseconds()
	if totalLatency <= 0 {
		totalLatency = connectLatency
	}
	return extractTraceIP(raw), totalLatency
}

func runDeepProbe(ctx context.Context) deepProbeResult {
	probeCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	var result deepProbeResult
	result.NatType = "UDP 受限或超时"

	var wg sync.WaitGroup
	var stunMapped netip.AddrPort
	var stunOK bool
	var directIP, proxyIP string
	var directLatency, proxyLatency int64

	wg.Add(3)
	go func() {
		defer wg.Done()
		for _, server := range []string{"stun.cloudflare.com:3478", "stun.miwifi.com:3478"} {
			if ap, err := probeStunServer(probeCtx, server); err == nil && ap.IsValid() {
				stunMapped = ap
				stunOK = true
				return
			}
			if probeCtx.Err() != nil {
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		directIP, directLatency = probeDirectConnectivity(probeCtx)
	}()
	go func() {
		defer wg.Done()
		proxyIP, proxyLatency = probeProxyConnectivity(probeCtx)
	}()
	wg.Wait()

	if stunOK {
		result.NatType = "UDP 可达 (STUN)"
		result.StunMapped = stunMapped.String()
	}
	result.DirectIP = directIP
	result.DirectLatency = directLatency
	result.ProxyIP = proxyIP
	result.ProxyLatency = proxyLatency

	parts := []string{"NAT: " + result.NatType}
	if result.StunMapped != "" {
		parts = append(parts, "STUN映射: "+result.StunMapped)
	}
	if result.DirectLatency > 0 {
		if result.DirectIP != "" {
			parts = append(parts, fmt.Sprintf("直连: %s (%dms)", result.DirectIP, result.DirectLatency))
		} else {
			parts = append(parts, fmt.Sprintf("直连: %dms", result.DirectLatency))
		}
	}
	if result.ProxyLatency > 0 {
		if result.ProxyIP != "" {
			parts = append(parts, fmt.Sprintf("代理: %s (%dms)", result.ProxyIP, result.ProxyLatency))
		} else {
			parts = append(parts, fmt.Sprintf("代理: %dms", result.ProxyLatency))
		}
	}
	result.Summary = strings.Join(parts, " · ")
	return result
}

func tunnelViews(instance *daemon.Instance) []tunnelView {
	views := []tunnelView{}
	if instance == nil || instance.Box() == nil || instance.Box().Endpoint() == nil {
		return views
	}
	for _, ep := range instance.Box().Endpoint().Endpoints() {
		if ep == nil {
			continue
		}
		epType := ep.Type()
		switch epType {
		case "wireguard":
			view := tunnelView{
				Tag:     ep.Tag(),
				Type:    epType,
				Active:  false,
				Summary: "WireGuard 用户态隧道已加载",
			}
			if source, ok := ep.(interface{ HarmonyWireGuardStatus() string }); ok {
				var data struct {
					Active bool            `json:"active"`
					Peers  []wireGuardPeer `json:"peers"`
				}
				if json.Unmarshal([]byte(source.HarmonyWireGuardStatus()), &data) == nil {
					view.Active = data.Active
					if data.Active {
						view.Summary = fmt.Sprintf("活跃 · %d 个节点", len(data.Peers))
					} else {
						view.Summary = fmt.Sprintf("等待握手 · %d 个节点", len(data.Peers))
					}
				}
			}
			views = append(views, view)
		case "tailscale":
			views = append(views, tunnelView{
				Tag:     ep.Tag(),
				Type:    epType,
				Active:  true,
				Summary: "Tailscale 用户态隧道运行中",
			})
		case "openvpn-client":
			views = append(views, tunnelView{
				Tag:     ep.Tag(),
				Type:    epType,
				Active:  true,
				Summary: "OpenVPN 用户态隧道运行中",
			})
		case "openconnect":
			views = append(views, tunnelView{
				Tag:     ep.Tag(),
				Type:    epType,
				Active:  true,
				Summary: "OpenConnect 用户态隧道运行中",
			})
		}
	}
	return views
}
