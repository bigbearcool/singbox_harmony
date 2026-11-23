package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/sagernet/sing-box/experimental/libbox"
)

type flexString string

func (f *flexString) UnmarshalJSON(data []byte) error {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" || trimmed == "null" {
		*f = ""
		return nil
	}
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		*f = flexString(s)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(data, &n); err == nil {
		*f = flexString(n.String())
		return nil
	}
	var b bool
	if err := json.Unmarshal(data, &b); err == nil {
		*f = flexString(strconv.FormatBool(b))
		return nil
	}
	*f = flexString(strings.Trim(trimmed, `"`))
	return nil
}

type flexInt int

func (f *flexInt) UnmarshalJSON(data []byte) error {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" || trimmed == "null" || trimmed == `""` {
		*f = 0
		return nil
	}
	var n int
	if err := json.Unmarshal(data, &n); err == nil {
		*f = flexInt(n)
		return nil
	}
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		s = strings.TrimSpace(s)
		if s == "" {
			*f = 0
			return nil
		}
		v, err := strconv.Atoi(s)
		if err != nil {
			return err
		}
		*f = flexInt(v)
		return nil
	}
	return fmt.Errorf("invalid integer: %s", trimmed)
}

func decodeBase64Flexible(input string) ([]byte, error) {
	cleaned := strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\t', '\r', '\n':
			return -1
		default:
			return r
		}
	}, input)
	if cleaned == "" {
		return nil, errors.New("empty base64")
	}
	encodings := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	for _, enc := range encodings {
		if decoded, err := enc.DecodeString(cleaned); err == nil && len(decoded) > 0 {
			return decoded, nil
		}
	}
	return nil, errors.New("invalid base64")
}

func hasSupportedScheme(text string) bool {
	lower := strings.ToLower(text)
	for _, prefix := range []string{"vless://", "vmess://", "trojan://", "ss://", "hy2://", "hysteria2://", "tuic://"} {
		if strings.Contains(lower, prefix) {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if trimmed := strings.TrimSpace(v); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func parseBoolParam(q url.Values, keys ...string) bool {
	for _, key := range keys {
		val := strings.ToLower(strings.TrimSpace(q.Get(key)))
		if val == "1" || val == "true" || val == "yes" {
			return true
		}
	}
	return false
}

func parsePort(raw string) (int, error) {
	port, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || port < 1 || port > 65535 {
		return 0, fmt.Errorf("无效端口: %s", raw)
	}
	return port, nil
}

func splitALPN(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	var result []string
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

func buildTransport(netType, host, path, serviceName string) map[string]any {
	switch strings.ToLower(strings.TrimSpace(netType)) {
	case "ws", "websocket":
		transport := map[string]any{"type": "ws"}
		if path != "" {
			transport["path"] = path
		}
		if host != "" {
			transport["headers"] = map[string]any{"Host": host}
		}
		return transport
	case "grpc":
		transport := map[string]any{"type": "grpc"}
		if serviceName != "" {
			transport["service_name"] = serviceName
		} else if path != "" {
			transport["service_name"] = strings.TrimPrefix(path, "/")
		}
		return transport
	case "http", "h2":
		transport := map[string]any{"type": "http"}
		if host != "" {
			transport["host"] = []string{host}
		}
		if path != "" {
			transport["path"] = path
		}
		return transport
	case "httpupgrade":
		transport := map[string]any{"type": "httpupgrade"}
		if host != "" {
			transport["host"] = host
		}
		if path != "" {
			transport["path"] = path
		}
		return transport
	default:
		return nil
	}
}

func buildTLSFromQuery(q url.Values, defaultEnabled bool) map[string]any {
	security := strings.ToLower(strings.TrimSpace(q.Get("security")))
	if security == "none" {
		return nil
	}
	enabled := defaultEnabled || security == "tls" || security == "reality"
	if !enabled {
		return nil
	}
	tlsObj := map[string]any{"enabled": true}
	if sni := firstNonEmpty(q.Get("sni"), q.Get("peer"), q.Get("host")); sni != "" {
		tlsObj["server_name"] = sni
	}
	if parseBoolParam(q, "allowInsecure", "insecure", "allow_insecure") {
		tlsObj["insecure"] = true
	}
	if alpn := splitALPN(q.Get("alpn")); len(alpn) > 0 {
		tlsObj["alpn"] = alpn
	}
	fp := strings.TrimSpace(q.Get("fp"))
	if security == "reality" {
		if fp == "" {
			fp = "chrome"
		}
		tlsObj["utls"] = map[string]any{
			"enabled":     true,
			"fingerprint": fp,
		}
		reality := map[string]any{
			"enabled":    true,
			"public_key": strings.TrimSpace(q.Get("pbk")),
		}
		if sid := strings.TrimSpace(q.Get("sid")); sid != "" {
			reality["short_id"] = sid
		}
		tlsObj["reality"] = reality
	} else if fp != "" {
		tlsObj["utls"] = map[string]any{
			"enabled":     true,
			"fingerprint": fp,
		}
	}
	return tlsObj
}

func unescapeTag(raw, fallback string) string {
	decoded, err := url.QueryUnescape(raw)
	if err != nil {
		decoded = raw
	}
	decoded = strings.TrimSpace(decoded)
	if decoded == "" {
		return fallback
	}
	return decoded
}

func parseVLESS(uri string) (map[string]any, string, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, "", err
	}
	uuid := strings.TrimSpace(u.User.Username())
	host := strings.TrimSpace(u.Hostname())
	port, err := parsePort(u.Port())
	if uuid == "" || host == "" || err != nil {
		return nil, "", errors.New("vless 节点参数不完整")
	}
	q := u.Query()
	out := map[string]any{
		"type":        "vless",
		"server":      host,
		"server_port": port,
		"uuid":        uuid,
	}
	if flow := strings.TrimSpace(q.Get("flow")); flow != "" {
		out["flow"] = flow
	}
	if pe := firstNonEmpty(q.Get("packetEncoding"), q.Get("packet_encoding")); pe != "" {
		out["packet_encoding"] = pe
	}
	if tlsObj := buildTLSFromQuery(q, false); tlsObj != nil {
		out["tls"] = tlsObj
	}
	if transport := buildTransport(firstNonEmpty(q.Get("type"), q.Get("net")), q.Get("host"), q.Get("path"), q.Get("serviceName")); transport != nil {
		out["transport"] = transport
	}
	tag := unescapeTag(u.Fragment, "vless-"+host)
	return out, tag, nil
}

func parseVMess(uri string) (map[string]any, string, error) {
	body := strings.TrimSpace(uri[len("vmess://"):])
	if idx := strings.IndexByte(body, '#'); idx >= 0 {
		body = body[:idx]
	}
	decoded, err := decodeBase64Flexible(body)
	if err != nil {
		return nil, "", errors.New("vmess Base64 解码失败")
	}
	var payload struct {
		PS            flexString `json:"ps"`
		Add           flexString `json:"add"`
		Port          flexInt    `json:"port"`
		ID            flexString `json:"id"`
		Aid           flexInt    `json:"aid"`
		Scy           flexString `json:"scy"`
		Security      flexString `json:"security"`
		Net           flexString `json:"net"`
		Host          flexString `json:"host"`
		Path          flexString `json:"path"`
		TLS           flexString `json:"tls"`
		SNI           flexString `json:"sni"`
		ALPN          flexString `json:"alpn"`
		FP            flexString `json:"fp"`
		AllowInsecure flexString `json:"allowInsecure"`
		Insecure      flexString `json:"insecure"`
	}
	if err := json.Unmarshal(decoded, &payload); err != nil {
		return nil, "", errors.New("vmess JSON 解析失败")
	}
	host := strings.TrimSpace(string(payload.Add))
	uuid := strings.TrimSpace(string(payload.ID))
	port := int(payload.Port)
	if host == "" || uuid == "" || port < 1 || port > 65535 {
		return nil, "", errors.New("vmess 节点参数不完整")
	}
	security := strings.ToLower(firstNonEmpty(string(payload.Scy), string(payload.Security), "auto"))
	switch security {
	case "auto", "none", "zero", "aes-128-cfb", "aes-128-gcm", "chacha20-poly1305":
	default:
		security = "auto"
	}
	out := map[string]any{
		"type":        "vmess",
		"server":      host,
		"server_port": port,
		"uuid":        uuid,
		"security":    security,
	}
	if payload.Aid > 0 {
		out["alter_id"] = int(payload.Aid)
	}
	tlsFlag := strings.ToLower(strings.TrimSpace(string(payload.TLS)))
	if tlsFlag == "tls" || tlsFlag == "1" || tlsFlag == "true" {
		tlsObj := map[string]any{"enabled": true}
		if sni := firstNonEmpty(string(payload.SNI), string(payload.Host)); sni != "" {
			tlsObj["server_name"] = sni
		}
		ins := strings.ToLower(firstNonEmpty(string(payload.AllowInsecure), string(payload.Insecure)))
		if ins == "1" || ins == "true" {
			tlsObj["insecure"] = true
		}
		if alpn := splitALPN(string(payload.ALPN)); len(alpn) > 0 {
			tlsObj["alpn"] = alpn
		}
		if fp := strings.TrimSpace(string(payload.FP)); fp != "" {
			tlsObj["utls"] = map[string]any{
				"enabled":     true,
				"fingerprint": fp,
			}
		}
		out["tls"] = tlsObj
	}
	if transport := buildTransport(string(payload.Net), string(payload.Host), string(payload.Path), string(payload.Path)); transport != nil {
		out["transport"] = transport
	}
	tag := firstNonEmpty(strings.TrimSpace(string(payload.PS)), "vmess-"+host)
	return out, tag, nil
}

func parseTrojan(uri string) (map[string]any, string, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, "", err
	}
	password := ""
	if u.User != nil {
		if pass, hasPass := u.User.Password(); hasPass {
			password = u.User.Username() + ":" + pass
		} else {
			password = u.User.Username()
		}
	}
	host := strings.TrimSpace(u.Hostname())
	port, err := parsePort(u.Port())
	if password == "" || host == "" || err != nil {
		return nil, "", errors.New("trojan 节点参数不完整")
	}
	q := u.Query()
	out := map[string]any{
		"type":        "trojan",
		"server":      host,
		"server_port": port,
		"password":    password,
	}
	if tlsObj := buildTLSFromQuery(q, true); tlsObj != nil {
		out["tls"] = tlsObj
	}
	if transport := buildTransport(firstNonEmpty(q.Get("type"), q.Get("net")), q.Get("host"), q.Get("path"), q.Get("serviceName")); transport != nil {
		out["transport"] = transport
	}
	tag := unescapeTag(u.Fragment, "trojan-"+host)
	return out, tag, nil
}

func parseShadowsocks(uri string) (map[string]any, string, error) {
	raw := strings.TrimSpace(uri[len("ss://"):])
	fragment := ""
	if idx := strings.IndexByte(raw, '#'); idx >= 0 {
		fragment = raw[idx+1:]
		raw = raw[:idx]
	}
	queryStr := ""
	if idx := strings.IndexByte(raw, '?'); idx >= 0 {
		queryStr = raw[idx+1:]
		raw = raw[:idx]
	}
	raw = strings.TrimSuffix(raw, "/")

	var userInfo, hostPort string
	if at := strings.LastIndexByte(raw, '@'); at >= 0 {
		userInfo = raw[:at]
		hostPort = raw[at+1:]
		if !strings.Contains(userInfo, ":") {
			decoded, err := decodeBase64Flexible(userInfo)
			if err != nil {
				return nil, "", errors.New("ss 用户信息 Base64 解码失败")
			}
			userInfo = string(decoded)
		} else if unescaped, err := url.QueryUnescape(userInfo); err == nil {
			userInfo = unescaped
		}
	} else {
		decoded, err := decodeBase64Flexible(raw)
		if err != nil {
			return nil, "", errors.New("ss 旧版链接 Base64 解码失败")
		}
		text := string(decoded)
		at := strings.LastIndexByte(text, '@')
		if at < 0 {
			return nil, "", errors.New("ss 链接缺少服务器地址")
		}
		userInfo = text[:at]
		hostPort = text[at+1:]
	}

	colon := strings.IndexByte(userInfo, ':')
	if colon <= 0 {
		return nil, "", errors.New("ss 加密方式或密码无效")
	}
	method := strings.TrimSpace(userInfo[:colon])
	password := userInfo[colon+1:]

	host, portStr, err := net.SplitHostPort(hostPort)
	if err != nil {
		return nil, "", errors.New("ss 服务器地址或端口无效")
	}
	port, err := parsePort(portStr)
	if host == "" || err != nil {
		return nil, "", errors.New("ss 服务器端口无效")
	}

	out := map[string]any{
		"type":        "shadowsocks",
		"server":      host,
		"server_port": port,
		"method":      method,
		"password":    password,
	}
	if queryStr != "" {
		if q, err := url.ParseQuery(queryStr); err == nil {
			if pluginRaw := strings.TrimSpace(q.Get("plugin")); pluginRaw != "" {
				if semi := strings.IndexByte(pluginRaw, ';'); semi >= 0 {
					out["plugin"] = strings.TrimSpace(pluginRaw[:semi])
					out["plugin_opts"] = strings.TrimSpace(pluginRaw[semi+1:])
				} else {
					out["plugin"] = pluginRaw
				}
			}
		}
	}
	tag := unescapeTag(fragment, "ss-"+host)
	return out, tag, nil
}

func parseHysteria2(uri string) (map[string]any, string, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, "", err
	}
	password := ""
	if u.User != nil {
		if pass, hasPass := u.User.Password(); hasPass {
			password = u.User.Username() + ":" + pass
		} else {
			password = u.User.Username()
		}
	}
	host := strings.TrimSpace(u.Hostname())
	port, err := parsePort(u.Port())
	if host == "" || err != nil {
		return nil, "", errors.New("hysteria2 节点参数不完整")
	}
	q := u.Query()
	tlsObj := map[string]any{"enabled": true}
	if sni := firstNonEmpty(q.Get("sni"), q.Get("peer")); sni != "" {
		tlsObj["server_name"] = sni
	}
	if parseBoolParam(q, "insecure", "allowInsecure", "allow_insecure") {
		tlsObj["insecure"] = true
	}
	if alpn := splitALPN(q.Get("alpn")); len(alpn) > 0 {
		tlsObj["alpn"] = alpn
	}
	out := map[string]any{
		"type":        "hysteria2",
		"server":      host,
		"server_port": port,
		"password":    password,
		"tls":         tlsObj,
	}
	if obfsType := strings.TrimSpace(q.Get("obfs")); obfsType != "" {
		obfsObj := map[string]any{"type": obfsType}
		if obfsPass := q.Get("obfs-password"); obfsPass != "" {
			obfsObj["password"] = obfsPass
		}
		out["obfs"] = obfsObj
	}
	if up, err := strconv.Atoi(strings.TrimSpace(q.Get("upmbps"))); err == nil && up > 0 {
		out["up_mbps"] = up
	}
	if down, err := strconv.Atoi(strings.TrimSpace(q.Get("downmbps"))); err == nil && down > 0 {
		out["down_mbps"] = down
	}
	tag := unescapeTag(u.Fragment, "hy2-"+host)
	return out, tag, nil
}

func parseTUIC(uri string) (map[string]any, string, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, "", err
	}
	uuid := ""
	password := ""
	if u.User != nil {
		uuid = strings.TrimSpace(u.User.Username())
		password, _ = u.User.Password()
	}
	host := strings.TrimSpace(u.Hostname())
	port, err := parsePort(u.Port())
	if uuid == "" || host == "" || err != nil {
		return nil, "", errors.New("tuic 节点参数不完整")
	}
	q := u.Query()
	tlsObj := map[string]any{"enabled": true}
	if sni := firstNonEmpty(q.Get("sni"), q.Get("peer")); sni != "" {
		tlsObj["server_name"] = sni
	}
	if parseBoolParam(q, "allow_insecure", "allowInsecure", "insecure") {
		tlsObj["insecure"] = true
	}
	if alpn := splitALPN(q.Get("alpn")); len(alpn) > 0 {
		tlsObj["alpn"] = alpn
	}
	out := map[string]any{
		"type":        "tuic",
		"server":      host,
		"server_port": port,
		"uuid":        uuid,
		"password":    password,
		"tls":         tlsObj,
	}
	switch cc := strings.ToLower(strings.TrimSpace(q.Get("congestion_control"))); cc {
	case "cubic", "new_reno", "bbr":
		out["congestion_control"] = cc
	}
	switch mode := strings.ToLower(strings.TrimSpace(q.Get("udp_relay_mode"))); mode {
	case "native", "quic":
		out["udp_relay_mode"] = mode
	}
	if parseBoolParam(q, "reduce_rtt", "zero_rtt_handshake") {
		out["zero_rtt_handshake"] = true
	}
	tag := unescapeTag(u.Fragment, "tuic-"+host)
	return out, tag, nil
}

func parseNodeURI(line string) (map[string]any, string, error) {
	lower := strings.ToLower(line)
	switch {
	case strings.HasPrefix(lower, "vless://"):
		return parseVLESS(line)
	case strings.HasPrefix(lower, "vmess://"):
		return parseVMess(line)
	case strings.HasPrefix(lower, "trojan://"):
		return parseTrojan(line)
	case strings.HasPrefix(lower, "ss://"):
		return parseShadowsocks(line)
	case strings.HasPrefix(lower, "hy2://"), strings.HasPrefix(lower, "hysteria2://"):
		return parseHysteria2(line)
	case strings.HasPrefix(lower, "tuic://"):
		return parseTUIC(line)
	default:
		return nil, "", errors.New("不支持的节点协议")
	}
}

func convertSubscriptionWithCount(raw string) (string, int, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "", 0, errors.New("订阅内容为空")
	}
	if !hasSupportedScheme(text) {
		decoded, err := decodeBase64Flexible(text)
		if err != nil || !hasSupportedScheme(string(decoded)) {
			return "", 0, errors.New("未识别到支持的节点链接（支持 vless/vmess/trojan/ss/hy2/tuic 或 Base64 订阅）")
		}
		text = string(decoded)
	}

	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	lines := strings.Split(text, "\n")

	usedTags := map[string]bool{
		"Proxy":  true,
		"Auto":   true,
		"direct": true,
	}
	var parsedOutbounds []map[string]any
	var parsedTags []string

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		out, baseTag, err := parseNodeURI(trimmed)
		if err != nil {
			continue
		}
		tag := baseTag
		if usedTags[tag] {
			for n := 2; ; n++ {
				candidate := fmt.Sprintf("%s-%d", baseTag, n)
				if !usedTags[candidate] {
					tag = candidate
					break
				}
			}
		}
		usedTags[tag] = true
		out["tag"] = tag
		parsedOutbounds = append(parsedOutbounds, out)
		parsedTags = append(parsedTags, tag)
	}

	if len(parsedOutbounds) == 0 {
		return "", 0, errors.New("未解析到任何有效节点")
	}

	selectorOutbounds := make([]string, 0, len(parsedTags)+2)
	selectorOutbounds = append(selectorOutbounds, "Auto", "direct")
	selectorOutbounds = append(selectorOutbounds, parsedTags...)

	outbounds := make([]map[string]any, 0, len(parsedOutbounds)+3)
	outbounds = append(outbounds,
		map[string]any{
			"type":      "selector",
			"tag":       "Proxy",
			"outbounds": selectorOutbounds,
			"default":   "Auto",
		},
		map[string]any{
			"type":      "urltest",
			"tag":       "Auto",
			"outbounds": parsedTags,
		},
	)
	outbounds = append(outbounds, parsedOutbounds...)
	outbounds = append(outbounds, map[string]any{
		"type": "direct",
		"tag":  "direct",
	})

	profile := map[string]any{
		"outbounds": outbounds,
		"route": map[string]any{
			"final":                 "Proxy",
			"auto_detect_interface": true,
		},
	}

	encoded, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return "", 0, err
	}
	jsonStr := string(encoded)

	normalized, err := normalizeConfig(jsonStr)
	if err != nil {
		return "", 0, fmt.Errorf("生成的配置规范化失败: %w", err)
	}
	if err := libbox.CheckConfig(normalized); err != nil {
		return "", 0, fmt.Errorf("生成的配置未通过 sing-box 校验: %w", err)
	}
	return jsonStr, len(parsedOutbounds), nil
}

func convertSubscriptionToSingbox(raw string) (string, error) {
	converted, _, err := convertSubscriptionWithCount(raw)
	return converted, err
}
