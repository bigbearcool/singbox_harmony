//go:build with_wireguard && with_gvisor

package main

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/sagernet/sing-box/log"
	WG "github.com/sagernet/sing-box/transport/wireguard"
	"github.com/sagernet/sing/common/control"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service/pause"
)

type protectedTestDialer struct {
	protected     atomic.Int64
	dialCalls     atomic.Int64
	packetCalls   atomic.Int64
	standardCalls atomic.Int64
	deny          bool
}

func (d *protectedTestDialer) protect(_ string, _ string, raw syscall.RawConn) error {
	if d.deny {
		return syscall.EPERM
	}
	return raw.Control(func(fd uintptr) {
		if fd > 0 {
			d.protected.Add(1)
		}
	})
}
func (d *protectedTestDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	d.dialCalls.Add(1)
	dialer := net.Dialer{Control: d.protect}
	return dialer.DialContext(ctx, network, destination.String())
}
func (d *protectedTestDialer) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	d.packetCalls.Add(1)
	listener := net.ListenConfig{Control: d.protect}
	return listener.ListenPacket(ctx, "udp", "")
}
func (d *protectedTestDialer) UDPListenerControl() (control.Func, bool) {
	return func(network, address string, raw syscall.RawConn) error {
		d.standardCalls.Add(1)
		return d.protect(network, address, raw)
	}, false
}
func testWGKeys(t *testing.T) (string, string) {
	t.Helper()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(key.Bytes()), base64.StdEncoding.EncodeToString(key.PublicKey().Bytes())
}
func wgState(t *testing.T, e *WG.Endpoint) WG.HarmonyStatus {
	t.Helper()
	var state WG.HarmonyStatus
	if err := json.Unmarshal([]byte(e.HarmonyWireGuardStatus()), &state); err != nil {
		t.Fatal(err)
	}
	return state
}

// Two ephemeral userspace peers exchange authenticated/encrypted packets over
// loopback. No physical TUN, real peer keys or household services are accessed.
func TestProtectedWireGuardEncryptedRoundTrip(t *testing.T) {
	for _, outer := range []string{"127.0.0.1", "::1", "peer.test.invalid"} {
		t.Run(outer, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			ctx = pause.WithDefaultManager(ctx)
			serverKey, serverPub := testWGKeys(t)
			clientKey, clientPub := testWGKeys(t)
			serverDialer := &protectedTestDialer{}
			clientDialer := &protectedTestDialer{}
			server, err := WG.NewEndpoint(WG.EndpointOptions{Context: ctx, Logger: log.NewNOPFactory().Logger(), Dialer: serverDialer, PrivateKey: serverKey, MTU: 1280, Address: []netip.Prefix{netip.MustParsePrefix("10.250.91.1/32"), netip.MustParsePrefix("fd97:beef:91::1/128")}, Peers: []WG.PeerOptions{{PublicKey: clientPub, AllowedIPs: []netip.Prefix{netip.MustParsePrefix("10.250.91.2/32"), netip.MustParsePrefix("fd97:beef:91::2/128")}}}})
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			if err = server.Start(false); err != nil {
				t.Fatal(err)
			}
			var port int
			for i := 0; i < 100; i++ {
				port = wgState(t, server).ListenPort
				if port > 0 {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if port == 0 {
				t.Fatal("test server did not bind")
			}
			peer := M.ParseSocksaddrHostPort(outer, uint16(port))
			client, err := WG.NewEndpoint(WG.EndpointOptions{Context: ctx, Logger: log.NewNOPFactory().Logger(), Dialer: clientDialer, PlatformClientBind: true, PrivateKey: clientKey, MTU: 1280, Address: []netip.Prefix{netip.MustParsePrefix("10.250.91.2/32"), netip.MustParsePrefix("fd97:beef:91::2/128")}, ResolvePeer: func(string) ([]netip.Addr, error) { return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil }, Peers: []WG.PeerOptions{{PublicKey: serverPub, Endpoint: peer, AllowedIPs: []netip.Prefix{netip.MustParsePrefix("10.250.91.1/32"), netip.MustParsePrefix("fd97:beef:91::1/128")}}}})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if err = client.Start(false); err != nil {
				t.Fatal(err)
			}
			if err = client.Start(true); err != nil {
				t.Fatal(err)
			}
			for _, inner := range []string{"10.250.91.1", "fd97:beef:91::1"} {
				packet, err := server.ListenPacket(ctx, M.Socksaddr{Addr: netip.MustParseAddr(inner)})
				if err != nil {
					t.Logf("loopback client status: %s; server status: %s", client.HarmonyWireGuardStatus(), server.HarmonyWireGuardStatus())
					t.Fatal(err)
				}
				defer packet.Close()
				packet.SetReadDeadline(time.Now().Add(7 * time.Second))
				returned := make(chan error, 1)
				go func() {
					buffer := make([]byte, 1500)
					n, from, err := packet.ReadFrom(buffer)
					if err == nil {
						_, err = packet.WriteTo(buffer[:n], from)
					}
					returned <- err
				}()
				destination := M.Socksaddr{Addr: netip.MustParseAddr(inner), Port: M.SocksaddrFromNet(packet.LocalAddr()).Port}
				conn, err := client.DialContext(ctx, "udp", destination)
				if err != nil {
					t.Fatal(err)
				}
				conn.SetDeadline(time.Now().Add(7 * time.Second))
				payload := []byte("protected-wireguard-loopback-" + inner)
				if _, err = conn.Write(payload); err != nil {
					conn.Close()
					t.Fatal(err)
				}
				buffer := make([]byte, 1500)
				n, err := conn.Read(buffer)
				conn.Close()
				if err != nil {
					t.Logf("loopback client status: %s; server status: %s", client.HarmonyWireGuardStatus(), server.HarmonyWireGuardStatus())
					t.Fatal(err)
				}
				if string(buffer[:n]) != string(payload) {
					t.Fatal("encrypted echo mismatch")
				}
				if err = <-returned; err != nil {
					t.Fatal(err)
				}
			}
			state := wgState(t, client)
			if state.Transport != "protected-client-udp" || len(state.Peers) != 1 || state.Peers[0].LastHandshake <= 0 || state.Peers[0].RxBytes <= 0 || state.Peers[0].TxBytes <= 0 {
				t.Fatal("missing authenticated peer and byte counters")
			}
			if clientDialer.protected.Load() == 0 || clientDialer.standardCalls.Load() != 0 {
				t.Fatal("encrypted socket bypassed the protected client dialer")
			}
			if outer == "peer.test.invalid" && clientDialer.packetCalls.Load() == 0 {
				t.Fatal("domain peer did not exercise protected packet socket")
			}
		})
	}
}
func TestWireGuardStatusNeverExportsUAPIKeys(t *testing.T) {
	raw := "private_key=PRIVATE_VALUE\nlisten_port=1234\npublic_key=PUBLIC_VALUE\npreshared_key=SECRET_VALUE\nendpoint=[2001:db8::7]:51820\nlast_handshake_time_sec=1700000000\ntx_bytes=123\nrx_bytes=321\nallowed_ip=10.20.0.0/16\n"
	state := WG.ParseHarmonyWireGuardStatus(raw)
	encoded, _ := json.Marshal(state)
	for _, private := range []string{"PRIVATE_VALUE", "PUBLIC_VALUE", "SECRET_VALUE", "2001:db8::7", "10.20.0.0"} {
		if strings.Contains(string(encoded), private) {
			t.Fatal("private UAPI field leaked")
		}
	}
	if len(state.Peers) != 1 || state.Peers[0].LastHandshake != 1700000000 || state.Peers[0].EndpointFamily != 6 || state.Peers[0].RxBytes != 321 {
		t.Fatal(fmt.Sprintf("invalid public status counters"))
	}
}

func TestWireGuardStartupReportsProtectedSocketFailure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ctx = pause.WithDefaultManager(ctx)
	key, _ := testWGKeys(t)
	_, peer := testWGKeys(t)
	endpoint, err := WG.NewEndpoint(WG.EndpointOptions{Context: ctx, Logger: log.NewNOPFactory().Logger(), Dialer: &protectedTestDialer{deny: true}, PlatformClientBind: true, PrivateKey: key, MTU: 1280, Address: []netip.Prefix{netip.MustParsePrefix("10.250.92.2/32")}, Peers: []WG.PeerOptions{{PublicKey: peer, Endpoint: M.ParseSocksaddr("127.0.0.1:51820"), AllowedIPs: []netip.Prefix{netip.MustParsePrefix("10.250.92.1/32")}}}})
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.Close()
	if err = endpoint.Start(false); err == nil {
		t.Fatal("WireGuard reported startup success after protected UDP was denied")
	}
	if wgState(t, endpoint).Active {
		t.Fatal("failed protected socket exposed as an active device")
	}
}
