package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"unsafe"

	"github.com/sagernet/sing-box/experimental/libbox"
)

var lifecycle sync.Mutex
var running *libbox.CommandServer
var activePlatform *harmonyPlatform

type response struct {
	OK        bool   `json:"ok"`
	Message   string `json:"message"`
	ErrorCode string `json:"errorCode,omitempty"`
}

func result(err error, msg string) *C.char {
	code := ""
	if err != nil {
		msg = err.Error()
		if strings.Contains(strings.ToLower(msg), "start protected wireguard udp") {
			code, msg = wireGuardFailure(err, false)
			code = "wg-" + code
		}
	}
	b, _ := json.Marshal(response{OK: err == nil, Message: msg, ErrorCode: code})
	return C.CString(string(b))
}

//export SBFree
func SBFree(p *C.char) { C.free(unsafe.Pointer(p)) }

//export SBVersion
func SBVersion() *C.char {
	return C.CString("sing-box " + libbox.Version() + " · HarmonyOS 原生")
}

//export SBCheck
func SBCheck(config *C.char) *C.char {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	normalized, err := normalizeConfig(C.GoString(config))
	if err != nil {
		return result(err, "")
	}
	return result(libbox.CheckConfig(normalized), "配置有效")
}

//export SBStart
func SBStart(config *C.char, fd C.int, workPath *C.char, iface *C.char, tunName *C.char, netID C.int) (res *C.char) {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	defer func() {
		if r := recover(); r != nil {
			res = result(fmt.Errorf("内核启动异常: %v", r), "")
		}
	}()
	if running != nil {
		return result(fmt.Errorf("VPN 内核正在运行"), "")
	}
	if fd < 0 {
		return result(fmt.Errorf("无效 TUN 文件描述符"), "")
	}
	normalized, err := normalizeConfigForNetwork(C.GoString(config), interfaceHasIPv6(C.GoString(iface)))
	if err != nil {
		return result(err, "")
	}
	path := C.GoString(workPath)
	if err = privateSnapshot(path); err != nil {
		return result(fmt.Errorf("无法保护私有配置快照"), "")
	}
	normalized = runtimeSettings(normalized, path)
	activeLogRedactions = logRedactions(C.GoString(config))
	configureWireGuardDiagnostics(C.GoString(config))
	if err = libbox.Setup(&libbox.SetupOptions{BasePath: path, WorkingPath: path, TempPath: path, LogMaxLines: 100, OomKillerDisabled: true}); err != nil {
		return result(err, "")
	}
	platform := &harmonyPlatform{fd: int32(fd), iface: C.GoString(iface), tunName: C.GoString(tunName), netID: int32(netID)}
	if platform.netID <= 0 {
		return result(fmt.Errorf("底层网络 ID 无效"), "")
	}
	if platform.tunName == "" {
		return result(fmt.Errorf("TUN 接口名为空"), "")
	}
	server, err := libbox.NewCommandServer(&commandHandler{}, platform)
	if err != nil {
		return result(err, "")
	}
	// No command listener is opened. The app drives the lifecycle through this ABI.
	if err = server.StartOrReloadService(normalized, &libbox.OverrideOptions{}); err != nil {
		server.Close()
		return result(err, "")
	}
	running = server
	restoreSelections(C.GoString(config), path)
	activePlatform = platform
	return result(nil, "双栈 TUN 与 sing-box 内核已启动")
}

//export SBStop
func SBStop() *C.char {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if running != nil {
		// Closing CommandServer only stops control subscriptions; the daemon's
		// active service must be closed explicitly to release TUN and sockets.
		_ = running.CloseService()
		running.Close()
		running = nil
		activePlatform = nil
	}
	wireGuardTargets = nil
	wireGuardProbes = map[string]wireGuardProbe{}
	return result(nil, "已停止")
}

type trafficStats struct {
	Uplink        int64  `json:"uplink"`
	Downlink      int64  `json:"downlink"`
	IPv4Flows     int    `json:"ipv4Flows"`
	IPv6Flows     int    `json:"ipv6Flows"`
	BindSuccess   int64  `json:"bindSuccess"`
	BindFailure   int64  `json:"bindFailure"`
	LastBindError string `json:"lastBindError"`
	DNSError      string `json:"dnsError"`
}

//export SBStats
func SBStats() *C.char {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	var stats trafficStats
	if activePlatform != nil {
		stats.BindSuccess = activePlatform.bindSuccess.Load()
		stats.BindFailure = activePlatform.bindFailure.Load()
		if value := activePlatform.lastBindError.Load(); value != nil {
			stats.LastBindError = value.(string)
		}
	}
	if running != nil {
		stats.DNSError = dnsErrorClass(running)
		instance := running.Instance()
		if instance != nil && instance.TrafficManager() != nil {
			manager := instance.TrafficManager()
			stats.Uplink, stats.Downlink = manager.Total()
			seen := make(map[string]bool)
			for _, it := range append(manager.Connections(), manager.ClosedConnections()...) {
				id := it.ID.String()
				if seen[id] {
					continue
				}
				seen[id] = true
				if it.Metadata.Source.Addr.Is6() {
					stats.IPv6Flows++
				} else if it.Metadata.Source.Addr.Is4() {
					stats.IPv4Flows++
				}
			}
		}
	}
	data, _ := json.Marshal(stats)
	return C.CString(string(data))
}

//export SBControl
func SBControl(request *C.char) *C.char {
	return C.CString(coreControl(C.GoString(request)))
}

type commandHandler struct{}

func (*commandHandler) ServiceStop() error   { return nil }
func (*commandHandler) ServiceReload() error { return fmt.Errorf("请先停止再加载配置") }
func (*commandHandler) GetSystemProxyStatus() (*libbox.SystemProxyStatus, error) {
	return &libbox.SystemProxyStatus{}, nil
}
func (*commandHandler) SetSystemProxyEnabled(bool) error {
	return fmt.Errorf("不支持系统 HTTP 代理")
}
func (*commandHandler) TriggerNativeCrash() error       { return fmt.Errorf("不支持") }
func (*commandHandler) WriteDebugMessage(string)        {}
func (*commandHandler) ConnectSSHAgent() (int32, error) { return -1, fmt.Errorf("不支持") }
func main()                                             {}
