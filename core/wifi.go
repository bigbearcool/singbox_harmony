package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/sagernet/sing-box/experimental/libbox"
)

// SSID stays in the VPN process. BSSID is deliberately absent: the public
// GET_WIFI_INFO API can return a randomized MAC without a restricted permission.
type physicalNetworkState struct {
	Type string `json:"type"`
	SSID string `json:"ssid"`
}

func parsePhysicalNetworkState(input string) (physicalNetworkState, error) {
	var state physicalNetworkState
	if err := json.Unmarshal([]byte(input), &state); err != nil {
		return state, fmt.Errorf("网络状态无效")
	}
	if state.Type != "wifi" && state.Type != "cellular" && state.Type != "other" {
		return state, fmt.Errorf("未知网络类型")
	}
	if !utf8.ValidString(state.SSID) || len(state.SSID) > 32 || strings.ContainsRune(state.SSID, 0) {
		return state, fmt.Errorf("Wi-Fi 状态无效")
	}
	if state.Type != "wifi" {
		state.SSID = ""
	}
	return state, nil
}

func (p *harmonyPlatform) ReadWIFIState() *libbox.WIFIState {
	p.wifiMu.RLock()
	defer p.wifiMu.RUnlock()
	return libbox.NewWIFIState(p.networkState.SSID, "")
}

func (p *harmonyPlatform) setNetworkState(state physicalNetworkState) bool {
	p.wifiMu.Lock()
	defer p.wifiMu.Unlock()
	changed := p.networkState != state
	p.networkState = state
	return changed
}

func (p *harmonyPlatform) networkType() int32 {
	p.wifiMu.RLock()
	defer p.wifiMu.RUnlock()
	switch p.networkState.Type {
	case "wifi":
		return libbox.InterfaceTypeWIFI
	case "cellular":
		return libbox.InterfaceTypeCellular
	default:
		return libbox.InterfaceTypeOther
	}
}
