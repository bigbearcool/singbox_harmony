package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"net/netip"
	"testing"
	"time"
)

func buildTestStunXorResponse(txID []byte, addr netip.AddrPort) []byte {
	var attrVal []byte
	xPort := addr.Port() ^ uint16(stunMagicCookie>>16)
	if addr.Addr().Is4() {
		attrVal = make([]byte, 8)
		attrVal[1] = 0x01
		binary.BigEndian.PutUint16(attrVal[2:4], xPort)
		ip4 := addr.Addr().As4()
		var cookie [4]byte
		binary.BigEndian.PutUint32(cookie[:], stunMagicCookie)
		for i := 0; i < 4; i++ {
			attrVal[4+i] = ip4[i] ^ cookie[i]
		}
	} else {
		attrVal = make([]byte, 20)
		attrVal[1] = 0x02
		binary.BigEndian.PutUint16(attrVal[2:4], xPort)
		ip6 := addr.Addr().As16()
		var mask [16]byte
		binary.BigEndian.PutUint32(mask[0:4], stunMagicCookie)
		copy(mask[4:16], txID)
		for i := 0; i < 16; i++ {
			attrVal[4+i] = ip6[i] ^ mask[i]
		}
	}

	attr := make([]byte, 4+len(attrVal))
	binary.BigEndian.PutUint16(attr[0:2], stunAttrXorMappedAddress)
	binary.BigEndian.PutUint16(attr[2:4], uint16(len(attrVal)))
	copy(attr[4:], attrVal)

	pkt := make([]byte, stunHeaderSize+len(attr))
	binary.BigEndian.PutUint16(pkt[0:2], stunBindingSuccessType)
	binary.BigEndian.PutUint16(pkt[2:4], uint16(len(attr)))
	binary.BigEndian.PutUint32(pkt[4:8], stunMagicCookie)
	copy(pkt[8:20], txID)
	copy(pkt[20:], attr)
	return pkt
}

func TestStunBindingRequestEncoding(t *testing.T) {
	txID := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	pkt, err := buildStunBindingRequest(txID)
	if err != nil {
		t.Fatal(err)
	}
	if len(pkt) != stunHeaderSize {
		t.Fatalf("expected 20-byte request, got %d", len(pkt))
	}
	if got := binary.BigEndian.Uint16(pkt[0:2]); got != stunBindingRequestType {
		t.Fatalf("unexpected type: 0x%04x", got)
	}
	if got := binary.BigEndian.Uint16(pkt[2:4]); got != 0 {
		t.Fatalf("expected zero length, got %d", got)
	}
	if got := binary.BigEndian.Uint32(pkt[4:8]); got != stunMagicCookie {
		t.Fatalf("unexpected magic cookie: 0x%08x", got)
	}
	if !bytes.Equal(pkt[8:20], txID) {
		t.Fatalf("txID mismatch: %x", pkt[8:20])
	}
	if _, err := buildStunBindingRequest([]byte{1, 2, 3}); err == nil {
		t.Fatal("expected error for invalid txID length")
	}
}

func TestStunXorMappedAddressIPv4AndIPv6(t *testing.T) {
	txID := []byte{0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}

	for _, wantStr := range []string{
		"203.0.113.42:54321",
		"[2001:db8:85a3::8a2e:370:7334]:41641",
	} {
		want := netip.MustParseAddrPort(wantStr)
		resp := buildTestStunXorResponse(txID, want)
		got, err := parseStunBindingResponse(resp, txID)
		if err != nil {
			t.Fatalf("parseStunBindingResponse(%s) failed: %v", wantStr, err)
		}
		if got != want {
			t.Fatalf("got %s, want %s", got, want)
		}
	}
}

func TestStunResponseValidationErrors(t *testing.T) {
	txID := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
	valid := buildTestStunXorResponse(txID, netip.MustParseAddrPort("198.51.100.10:12345"))

	if _, err := parseStunBindingResponse(valid[:10], txID); err == nil {
		t.Fatal("expected error for short packet")
	}
	wrongTx := append([]byte(nil), valid...)
	wrongTx[19] ^= 0xff
	if _, err := parseStunBindingResponse(wrongTx, txID); err == nil {
		t.Fatal("expected error for txID mismatch")
	}
	wrongMagic := append([]byte(nil), valid...)
	wrongMagic[4] ^= 0xff
	if _, err := parseStunBindingResponse(wrongMagic, txID); err == nil {
		t.Fatal("expected error for bad magic cookie")
	}
	wrongType := append([]byte(nil), valid...)
	binary.BigEndian.PutUint16(wrongType[0:2], 0x0111)
	if _, err := parseStunBindingResponse(wrongType, txID); err == nil {
		t.Fatal("expected error for error response type")
	}
}

func TestProbeStunServerOfflineLoopback(t *testing.T) {
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()

	want := netip.MustParseAddrPort("198.51.100.77:51820")
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 1500)
		_ = pc.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, addr, err := pc.ReadFrom(buf)
		if err != nil || n < stunHeaderSize {
			return
		}
		resp := buildTestStunXorResponse(buf[8:20], want)
		_, _ = pc.WriteTo(resp, addr)
	}()

	got, err := probeStunServer(context.Background(), pc.LocalAddr().String())
	<-done
	if err != nil {
		t.Fatalf("probeStunServer failed: %v", err)
	}
	if got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestExtractTraceIPAndTunnelViewsNil(t *testing.T) {
	body := []byte("fl=29f12\nh=1.1.1.1\nip=203.0.113.88\nts=1700000000\n")
	if got := extractTraceIP(body); got != "203.0.113.88" {
		t.Fatalf("got %q, want 203.0.113.88", got)
	}
	if views := tunnelViews(nil); views == nil || len(views) != 0 {
		t.Fatalf("expected empty non-nil tunnelViews for nil instance, got %#v", views)
	}
}
