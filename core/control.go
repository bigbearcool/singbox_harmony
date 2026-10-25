package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/sagernet/sing-box/daemon"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

type controlRequest struct {
	Action   string `json:"action"`
	Group    string `json:"group"`
	Outbound string `json:"outbound"`
	ID       string `json:"id"`
	Mode     string `json:"mode"`
}

type groupSnapshot struct {
	grpc.ServerStream
	ctx    context.Context
	groups []*daemon.Group
}

func (s *groupSnapshot) Context() context.Context        { return s.ctx }
func (s *groupSnapshot) Send(value *daemon.Groups) error { s.groups = value.Group; return io.EOF }

type connectionView struct {
	ID          string `json:"id"`
	Network     string `json:"network"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Domain      string `json:"domain"`
	Outbound    string `json:"outbound"`
	Rule        string `json:"rule"`
	Upload      int64  `json:"upload"`
	Download    int64  `json:"download"`
	CreatedAt   int64  `json:"createdAt"`
}
type dashboardSnapshot struct {
	Groups      []*daemon.Group  `json:"groups"`
	Connections []connectionView `json:"connections"`
	Logs        []string         `json:"logs"`
	Modes       []string         `json:"modes"`
	Mode        string           `json:"mode"`
}
type controlReply struct {
	OK      bool               `json:"ok"`
	Message string             `json:"message"`
	Data    *dashboardSnapshot `json:"data,omitempty"`
}

var logURL = regexp.MustCompile(`https?://[^\s]+`)
var logSecret = regexp.MustCompile(`(?i)(password|private_key|token|authorization|uuid)["\s]*[:=]["\s]*[^\s,}"']+`)
var logIPv4 = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}\b`)
var logIPv6 = regexp.MustCompile(`\[[0-9a-fA-F:]+\]`)
var activeLogRedactions []string

func logRedactions(config string) []string {
	var root any
	if json.Unmarshal([]byte(config), &root) != nil {
		return nil
	}
	values := map[string]bool{}
	var walk func(any)
	walk = func(value any) {
		switch item := value.(type) {
		case map[string]any:
			for key, child := range item {
				switch key {
				case "server", "server_name", "address", "uuid", "password", "private_key", "public_key", "pre_shared_key", "short_id":
					if text, ok := child.(string); ok && len(text) > 3 {
						values[text] = true
					}
				}
				walk(child)
			}
		case []any:
			for _, child := range item {
				walk(child)
			}
		}
	}
	walk(root)
	var result []string
	for value := range values {
		result = append(result, value)
	}
	sort.Slice(result, func(i, j int) bool { return len(result[i]) > len(result[j]) })
	return result
}

func safeLog(value string) string {
	for _, secret := range activeLogRedactions {
		value = strings.ReplaceAll(value, secret, "[配置值]")
	}
	value = logURL.ReplaceAllString(value, "[URL]")
	value = logSecret.ReplaceAllString(value, "$1=[redacted]")
	value = logIPv4.ReplaceAllString(value, "[IP]")
	value = logIPv6.ReplaceAllString(value, "[IPv6]")
	if len(value) > 2048 {
		value = value[:2048]
	}
	return value
}

// Calls stay inside the VPN process. No TCP/Unix control listener is opened.
func coreControl(input string) string {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	reply := controlReply{Message: "内核操作失败"}
	var request controlRequest
	if err := json.Unmarshal([]byte(input), &request); err != nil || running == nil {
		reply.Message = "VPN 未运行或请求无效"
	} else {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		var err error
		switch request.Action {
		case "snapshot":
			data := &dashboardSnapshot{Groups: []*daemon.Group{}, Connections: []connectionView{}, Logs: []string{}, Modes: []string{}}
			groups := &groupSnapshot{ctx: ctx}
			_ = running.SubscribeGroups(&emptypb.Empty{}, groups)
			if groups.groups != nil {
				data.Groups = groups.groups
			}
			logs := &logSnapshot{}
			_ = running.SubscribeLog(&emptypb.Empty{}, logs)
			for _, line := range logs.entries {
				data.Logs = append(data.Logs, safeLog(line.Message))
			}
			if mode, e := running.GetClashModeStatus(ctx, &emptypb.Empty{}); e == nil {
				data.Modes = mode.ModeList
				data.Mode = mode.CurrentMode
			}
			if instance := running.Instance(); instance != nil && instance.TrafficManager() != nil {
				connections := instance.TrafficManager().Connections()
				sort.Slice(connections, func(i, j int) bool { return connections[i].CreatedAt.After(connections[j].CreatedAt) })
				if len(connections) > 200 {
					connections = connections[:200]
				}
				for _, conn := range connections {
					rule := ""
					if conn.Rule != nil {
						rule = conn.Rule.String()
						if len(rule) > 512 {
							rule = rule[:512] + "…"
						}
					}
					data.Connections = append(data.Connections, connectionView{ID: conn.ID.String(), Network: conn.Metadata.Network, Source: conn.Metadata.Source.String(), Destination: conn.Metadata.Destination.String(), Domain: conn.Metadata.Domain, Outbound: conn.Outbound, Rule: rule, Upload: conn.Upload.Load(), Download: conn.Download.Load(), CreatedAt: conn.CreatedAt.UnixMilli()})
				}
			}
			reply.Data = data
		case "select":
			_, err = running.SelectOutbound(ctx, &daemon.SelectOutboundRequest{GroupTag: request.Group, OutboundTag: request.Outbound})
			if err == nil && selectionStatePath != "" {
				if saveSelection(request.Group, request.Outbound) != nil {
					reply.Message = "已切换节点，但选择未能保存"
				}
			}
		case "urltest":
			_, err = running.URLTest(ctx, &daemon.URLTestRequest{OutboundTag: request.Outbound})
		case "close":
			_, err = running.CloseConnection(ctx, &daemon.CloseConnectionRequest{Id: request.ID})
		case "close-all":
			_, err = running.CloseAllConnections(ctx, &emptypb.Empty{})
		case "clear-logs":
			_, err = running.ClearLogs(ctx, &emptypb.Empty{})
		case "reset-network":
			running.ResetNetwork()
		case "mode":
			var modes *daemon.ClashModeStatus
			modes, err = running.GetClashModeStatus(ctx, &emptypb.Empty{})
			valid := false
			if err == nil {
				for _, mode := range modes.ModeList {
					if mode == request.Mode {
						valid = true
						break
					}
				}
			}
			if !valid {
				err = errors.New("mode unavailable")
			} else {
				_, err = running.SetClashMode(ctx, &daemon.ClashMode{Mode: request.Mode})
			}
		default:
			err = errors.New("unknown action")
		}
		if err == nil {
			reply.OK = true
			if reply.Message == "内核操作失败" {
				reply.Message = "操作完成"
			}
		}
	}
	data, _ := json.Marshal(reply)
	return string(data)
}
