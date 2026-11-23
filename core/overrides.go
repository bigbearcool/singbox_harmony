package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
)

const (
	maxOverridesBytes   = 256 * 1024
	localHostsServerTag = "local-hosts-override"
)

type HostOverride struct {
	Domain string   `json:"domain"`
	IPs    []string `json:"ips"`
}

type LocalOverrides struct {
	Enabled       bool           `json:"enabled"`
	Hosts         []HostOverride `json:"hosts"`
	DirectDomains []string       `json:"directDomains"`
	ProxyDomains  []string       `json:"proxyDomains"`
	RejectDomains []string       `json:"rejectDomains"`
	DirectCidrs   []string       `json:"directCidrs"`
	ProxyCidrs    []string       `json:"proxyCidrs"`
	RejectCidrs   []string       `json:"rejectCidrs"`
}

func loadLocalOverrides(dir string) LocalOverrides {
	if dir == "" {
		return LocalOverrides{}
	}
	file, err := os.Open(filepath.Join(dir, "overrides.json"))
	if err != nil {
		return LocalOverrides{}
	}
	defer file.Close()

	data, err := io.ReadAll(io.LimitReader(file, maxOverridesBytes+1))
	if err != nil || len(data) == 0 || len(data) > maxOverridesBytes {
		return LocalOverrides{}
	}

	var overrides LocalOverrides
	if err := json.Unmarshal(data, &overrides); err != nil || !overrides.Enabled {
		return LocalOverrides{}
	}
	return overrides
}

func applyLocalOverrides(normalizedConfig string, overrides LocalOverrides) (string, error) {
	if !overrides.Enabled {
		return normalizedConfig, nil
	}

	var cfg map[string]json.RawMessage
	if err := json.Unmarshal([]byte(normalizedConfig), &cfg); err != nil || cfg == nil {
		return "", errors.New("无效的 sing-box 配置 JSON")
	}

	var outbounds []struct {
		Type string `json:"type"`
		Tag  string `json:"tag"`
	}
	if raw, ok := cfg["outbounds"]; ok {
		if err := json.Unmarshal(raw, &outbounds); err != nil {
			return "", errors.New("无效的 outbounds 配置")
		}
	}

	var route map[string]json.RawMessage
	if raw, ok := cfg["route"]; ok && string(raw) != "null" {
		if err := json.Unmarshal(raw, &route); err != nil {
			return "", errors.New("无效的 route 配置")
		}
	}
	if route == nil {
		route = make(map[string]json.RawMessage)
	}

	var routeFinal string
	if raw, ok := route["final"]; ok {
		_ = json.Unmarshal(raw, &routeFinal)
	}

	directTags := make(map[string]bool)
	var directTag string
	for _, ob := range outbounds {
		if ob.Type == "direct" && ob.Tag != "" {
			directTags[ob.Tag] = true
			if directTag == "" {
				directTag = ob.Tag
			}
		}
	}

	proxyTag := ""
	if routeFinal != "" && !directTags[routeFinal] {
		proxyTag = routeFinal
	} else {
		for _, ob := range outbounds {
			if ob.Tag == "" {
				continue
			}
			switch ob.Type {
			case "direct", "block", "dns":
				continue
			default:
				proxyTag = ob.Tag
			}
			if proxyTag != "" {
				break
			}
		}
	}

	var overrideRules []json.RawMessage
	appendRule := func(rule map[string]any) {
		raw, err := json.Marshal(rule)
		if err == nil {
			overrideRules = append(overrideRules, raw)
		}
	}

	if domains := cleanDomains(overrides.RejectDomains); len(domains) > 0 {
		appendRule(map[string]any{"domain_suffix": domains, "action": "reject"})
	}
	if cidrs := cleanCIDRs(overrides.RejectCidrs); len(cidrs) > 0 {
		appendRule(map[string]any{"ip_cidr": cidrs, "action": "reject"})
	}
	if directTag != "" {
		if domains := cleanDomains(overrides.DirectDomains); len(domains) > 0 {
			appendRule(map[string]any{"domain_suffix": domains, "outbound": directTag})
		}
		if cidrs := cleanCIDRs(overrides.DirectCidrs); len(cidrs) > 0 {
			appendRule(map[string]any{"ip_cidr": cidrs, "outbound": directTag})
		}
	}
	if proxyTag != "" {
		if domains := cleanDomains(overrides.ProxyDomains); len(domains) > 0 {
			appendRule(map[string]any{"domain_suffix": domains, "outbound": proxyTag})
		}
		if cidrs := cleanCIDRs(overrides.ProxyCidrs); len(cidrs) > 0 {
			appendRule(map[string]any{"ip_cidr": cidrs, "outbound": proxyTag})
		}
	}

	if len(overrideRules) > 0 {
		var existingRules []json.RawMessage
		if raw, ok := route["rules"]; ok && string(raw) != "null" {
			if err := json.Unmarshal(raw, &existingRules); err != nil {
				return "", errors.New("无效的 route.rules 配置")
			}
		}
		hijackCount := 0
		for hijackCount < len(existingRules) && isHijackDNSRule(existingRules[hijackCount]) {
			hijackCount++
		}
		merged := make([]json.RawMessage, 0, len(existingRules)+len(overrideRules))
		merged = append(merged, existingRules[:hijackCount]...)
		merged = append(merged, overrideRules...)
		merged = append(merged, existingRules[hijackCount:]...)
		rulesJSON, err := json.Marshal(merged)
		if err != nil {
			return "", err
		}
		route["rules"] = rulesJSON
		routeJSON, err := json.Marshal(route)
		if err != nil {
			return "", err
		}
		cfg["route"] = routeJSON
	}

	hostDomains, predefined := cleanHosts(overrides.Hosts)
	if len(hostDomains) > 0 {
		var dnsCfg map[string]json.RawMessage
		if raw, ok := cfg["dns"]; ok && string(raw) != "null" {
			if err := json.Unmarshal(raw, &dnsCfg); err != nil {
				return "", errors.New("无效的 dns 配置")
			}
		}
		if dnsCfg == nil {
			dnsCfg = make(map[string]json.RawMessage)
		}

		var servers []json.RawMessage
		if raw, ok := dnsCfg["servers"]; ok && string(raw) != "null" {
			if err := json.Unmarshal(raw, &servers); err != nil {
				return "", errors.New("无效的 dns.servers 配置")
			}
		}
		hostsServerJSON, err := json.Marshal(map[string]any{
			"type":       "hosts",
			"tag":        localHostsServerTag,
			"predefined": predefined,
		})
		if err != nil {
			return "", err
		}
		replaced := false
		for i, raw := range servers {
			var meta struct {
				Tag string `json:"tag"`
			}
			if json.Unmarshal(raw, &meta) == nil && meta.Tag == localHostsServerTag {
				servers[i] = hostsServerJSON
				replaced = true
				break
			}
		}
		if !replaced {
			servers = append(servers, hostsServerJSON)
		}
		serversJSON, err := json.Marshal(servers)
		if err != nil {
			return "", err
		}
		dnsCfg["servers"] = serversJSON

		var dnsRules []json.RawMessage
		if raw, ok := dnsCfg["rules"]; ok && string(raw) != "null" {
			if err := json.Unmarshal(raw, &dnsRules); err != nil {
				return "", errors.New("无效的 dns.rules 配置")
			}
		}
		hostsRuleJSON, err := json.Marshal(map[string]any{
			"domain": hostDomains,
			"server": localHostsServerTag,
		})
		if err != nil {
			return "", err
		}
		mergedDNSRules := make([]json.RawMessage, 0, len(dnsRules)+1)
		mergedDNSRules = append(mergedDNSRules, hostsRuleJSON)
		mergedDNSRules = append(mergedDNSRules, dnsRules...)
		dnsRulesJSON, err := json.Marshal(mergedDNSRules)
		if err != nil {
			return "", err
		}
		dnsCfg["rules"] = dnsRulesJSON

		dnsJSON, err := json.Marshal(dnsCfg)
		if err != nil {
			return "", err
		}
		cfg["dns"] = dnsJSON
	}

	result, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return string(result), nil
}

func isHijackDNSRule(raw json.RawMessage) bool {
	var rule struct {
		Action string `json:"action"`
	}
	return json.Unmarshal(raw, &rule) == nil && rule.Action == "hijack-dns"
}

func cleanDomains(items []string) []string {
	if len(items) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(items))
	out := make([]string, 0, len(items))
	for _, item := range items {
		d := strings.ToLower(strings.TrimSpace(item))
		if d == "" || seen[d] {
			continue
		}
		seen[d] = true
		out = append(out, d)
	}
	return out
}

func cleanCIDRs(items []string) []string {
	if len(items) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(items))
	out := make([]string, 0, len(items))
	for _, item := range items {
		s := strings.TrimSpace(item)
		if s == "" {
			continue
		}
		if _, err := netip.ParsePrefix(s); err != nil {
			continue
		}
		if seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

func cleanHosts(hosts []HostOverride) ([]string, map[string][]string) {
	if len(hosts) == 0 {
		return nil, nil
	}
	predefined := make(map[string][]string)
	ipSeen := make(map[string]map[string]bool)
	domains := make([]string, 0, len(hosts))
	for _, h := range hosts {
		domain := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(h.Domain)), ".")
		if domain == "" {
			continue
		}
		if ipSeen[domain] == nil {
			ipSeen[domain] = make(map[string]bool)
		}
		for _, rawIP := range h.IPs {
			addr, err := netip.ParseAddr(strings.TrimSpace(rawIP))
			if err != nil {
				continue
			}
			ip := addr.String()
			if ipSeen[domain][ip] {
				continue
			}
			ipSeen[domain][ip] = true
			if len(predefined[domain]) == 0 {
				domains = append(domains, domain)
			}
			predefined[domain] = append(predefined[domain], ip)
		}
	}
	if len(domains) == 0 {
		return nil, nil
	}
	return domains, predefined
}
