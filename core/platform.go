package main

import (
	"fmt"
	"sync"

	"github.com/sagernet/sing-box/experimental/libbox"
)

var _ libbox.PlatformInterface = (*harmonyPlatform)(nil)

type harmonyPlatform struct {
	fd       int32
	iface    string
	mu       sync.Mutex
	listener libbox.InterfaceUpdateListener
}

func (*harmonyPlatform) LocalDNSTransport() libbox.LocalDNSTransport { return nil }

// API 22+ protectProcessNet is awaited by ArkTS before SBStart. A failure aborts startup.
func (*harmonyPlatform) UsePlatformAutoDetectInterfaceControl() bool { return true }
func (*harmonyPlatform) AutoDetectInterfaceControl(int32) error      { return nil }
func (p *harmonyPlatform) OpenTun(libbox.TunOptions) (int32, error)  { return p.fd, nil }
func (*harmonyPlatform) UseProcFS() bool                             { return false }
func (*harmonyPlatform) FindConnectionOwner(int32, string, int32, string, int32) (*libbox.ConnectionOwner, error) {
	return nil, fmt.Errorf("MVP 不支持进程规则")
}
func (p *harmonyPlatform) StartDefaultInterfaceMonitor(l libbox.InterfaceUpdateListener) error {
	p.mu.Lock()
	p.listener = l
	p.mu.Unlock()
	if p.iface == "" {
		return fmt.Errorf("物理网络接口不可用")
	}
	interfaces, err := nativeInterfaces()
	if err != nil {
		return err
	}
	for _, it := range interfaces {
		if it.Name == p.iface {
			l.UpdateDefaultInterface(it.Name, it.Index, false, false)
			return nil
		}
	}
	return fmt.Errorf("物理网络接口不存在: %s", p.iface)
}
func (p *harmonyPlatform) CloseDefaultInterfaceMonitor(libbox.InterfaceUpdateListener) error {
	p.mu.Lock()
	p.listener = nil
	p.mu.Unlock()
	return nil
}

type stringIterator struct {
	values []string
	at     int
}

func (i *stringIterator) HasNext() bool { return i.at < len(i.values) }
func (i *stringIterator) Len() int32    { return int32(len(i.values)) }
func (i *stringIterator) Next() string  { v := i.values[i.at]; i.at++; return v }

type interfaceIterator struct {
	values []*libbox.NetworkInterface
	at     int
}

func (i *interfaceIterator) HasNext() bool                  { return i.at < len(i.values) }
func (i *interfaceIterator) Next() *libbox.NetworkInterface { v := i.values[i.at]; i.at++; return v }
func (*harmonyPlatform) GetInterfaces() (libbox.NetworkInterfaceIterator, error) {
	interfaces, err := nativeInterfaces()
	if err != nil {
		return nil, err
	}
	return &interfaceIterator{values: interfaces}, nil
}
func (*harmonyPlatform) UnderNetworkExtension() bool                 { return true }
func (*harmonyPlatform) IncludeAllNetworks() bool                    { return true }
func (*harmonyPlatform) ReadWIFIState() *libbox.WIFIState            { return &libbox.WIFIState{} }
func (*harmonyPlatform) ClearDNSCache()                              {}
func (*harmonyPlatform) SendNotification(*libbox.Notification) error { return nil }
func (*harmonyPlatform) CancelNotification(string, int32) error      { return nil }
func (*harmonyPlatform) StartNeighborMonitor(libbox.NeighborUpdateListener) error {
	return fmt.Errorf("不支持邻居监控")
}
func (*harmonyPlatform) CloseNeighborMonitor(libbox.NeighborUpdateListener) error { return nil }
func (*harmonyPlatform) RegisterMyInterface(string)                               {}
func (*harmonyPlatform) UsePlatformShell() bool                                   { return false }
func (*harmonyPlatform) CheckPlatformShell() error                                { return fmt.Errorf("不支持 shell") }
func (*harmonyPlatform) OpenShellSession(*libbox.PlatformUser, string, libbox.StringIterator, string, int32, int32) (libbox.ShellSession, error) {
	return nil, fmt.Errorf("不支持 shell")
}
func (*harmonyPlatform) LookupUser(string) (*libbox.PlatformUser, error) {
	return nil, fmt.Errorf("不支持")
}
func (*harmonyPlatform) LookupSFTPServer() (string, error)     { return "", fmt.Errorf("不支持") }
func (*harmonyPlatform) ReadSystemSSHHostKey() (string, error) { return "", fmt.Errorf("不支持") }
func (*harmonyPlatform) TailscaleHostname() string             { return "" }
func (*harmonyPlatform) UsePlatformBridge() bool               { return false }
func (*harmonyPlatform) CreateBridge(*libbox.BridgeOptions) (libbox.BridgeSession, error) {
	return nil, fmt.Errorf("不支持网桥")
}
