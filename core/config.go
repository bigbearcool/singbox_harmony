package main

import (
	"encoding/json"
	"errors"
	"fmt"
)

// The system owns addresses/routes. The imported profile owns outbounds and rules.
// Never allow a profile to replace the dual-stack data plane or expose a listener.
func normalizeConfig(input string) (string, error) {
	var cfg map[string]json.RawMessage
	if err := json.Unmarshal([]byte(input), &cfg); err != nil {
		return "", errors.New("配置必须是 sing-box JSON 对象")
	}
	if cfg == nil {
		return "", errors.New("配置不能为空")
	}
	var outbounds []map[string]json.RawMessage
	if err := json.Unmarshal(cfg["outbounds"], &outbounds); err != nil || len(outbounds) == 0 {
		return "", errors.New("配置必须包含 outbounds")
	}
	// Reject unsupported app-managed surfaces instead of silently accepting partial VPNs.
	for _, field := range []string{"services", "endpoints"} {
		if raw, ok := cfg[field]; ok && string(raw) != "[]" && string(raw) != "null" {
			return "", fmt.Errorf("MVP 暂不支持 %s", field)
		}
	}
	delete(cfg, "experimental")
	cfg["inbounds"] = json.RawMessage(`[{"type":"tun","tag":"harmony-tun","address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"mtu":1280,"auto_route":false,"stack":"gvisor"}]`)
	var route map[string]json.RawMessage
	if raw, ok := cfg["route"]; ok {
		if err := json.Unmarshal(raw, &route); err != nil {
			return "", errors.New("route 格式无效")
		}
	}
	if route == nil {
		route = make(map[string]json.RawMessage)
	}
	if _, ok := cfg["dns"]; !ok {
		var final string
		_ = json.Unmarshal(route["final"], &final)
		if final == "" {
			_ = json.Unmarshal(outbounds[0]["tag"], &final)
		}
		server := map[string]any{"type": "https", "tag": "remote-dns", "server": "1.1.1.1", "path": "/dns-query"}
		if final != "" {
			server["detour"] = final
		}
		cfg["dns"], _ = json.Marshal(map[string]any{"servers": []any{server}, "final": "remote-dns", "strategy": "prefer_ipv6"})
	}
	// Netlink routing is unavailable inside the application sandbox.
	route["auto_detect_interface"] = json.RawMessage(`false`)
	delete(route, "default_interface")
	var rules []json.RawMessage
	if raw, ok := route["rules"]; ok {
		if err := json.Unmarshal(raw, &rules); err != nil {
			return "", errors.New("route.rules 格式无效")
		}
	}
	rules = append([]json.RawMessage{json.RawMessage(`{"protocol":"dns","action":"hijack-dns"}`), json.RawMessage(`{"port":53,"action":"hijack-dns"}`)}, rules...)
	route["rules"], _ = json.Marshal(rules)
	if _, ok := route["default_domain_resolver"]; !ok {
		{
			var dns struct {
				Final   string `json:"final"`
				Servers []struct {
					Tag string `json:"tag"`
				} `json:"servers"`
			}
			_ = json.Unmarshal(cfg["dns"], &dns)
			tag := dns.Final
			if tag == "" && len(dns.Servers) > 0 {
				tag = dns.Servers[0].Tag
			}
			if tag == "" {
				return "", errors.New("DNS server 必须有 tag")
			}
			route["default_domain_resolver"], _ = json.Marshal(map[string]string{"server": tag})
		}
	}
	cfg["route"], _ = json.Marshal(route)
	// Core logs may include destinations; retain them only inside the private sandbox.
	cfg["log"] = json.RawMessage(`{"level":"warn","timestamp":true}`)
	result, err := json.Marshal(cfg)
	return string(result), err
}
