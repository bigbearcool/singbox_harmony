package main

import (
	"io"
	"strings"

	"github.com/sagernet/sing-box/daemon"
	"github.com/sagernet/sing-box/experimental/libbox"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

type logSnapshot struct {
	grpc.ServerStream
	entries []*daemon.Log_Message
}

func (s *logSnapshot) Send(message *daemon.Log) error { s.entries = message.Messages; return io.EOF }

// Report only a diagnostic class, never destinations, domains or raw core logs.
func dnsErrorClass(server *libbox.CommandServer) string {
	snapshot := &logSnapshot{}
	_ = server.SubscribeLog(&emptypb.Empty{}, snapshot)
	for i := len(snapshot.entries) - 1; i >= 0; i-- {
		message := strings.ToLower(snapshot.entries[i].Message)
		if !strings.Contains(message, "dns") && !strings.Contains(message, "exchange") && !strings.Contains(message, "x509") {
			continue
		}
		for _, pair := range [][2]string{{"x509", "DNS TLS certificate verification failed"}, {"unknown authority", "DNS TLS certificate verification failed"}, {"timeout", "DNS upstream timeout"}, {"deadline exceeded", "DNS upstream timeout"}, {"network is unreachable", "DNS upstream network unreachable"}, {"permission denied", "DNS transport permission denied"}, {"exchange failed", "DNS exchange failed"}} {
			if strings.Contains(message, pair[0]) {
				return pair[1]
			}
		}
	}
	return ""
}
