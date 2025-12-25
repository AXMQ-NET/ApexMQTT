package main

import (
	"bytes"
	"net"
	"time"
)

func tcpDial(addr string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("tcp", addr, timeout)
}

func tcpAddrFromMQTTURL(mqttURL string) string {
	// Supports: tcp://host:port
	const p = "tcp://"
	if len(mqttURL) >= len(p) && mqttURL[:len(p)] == p {
		return mqttURL[len(p):]
	}
	return mqttURL
}

func mustReadSome(conn net.Conn, timeout time.Duration) ([]byte, error) {
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if n > 0 {
		return buf[:n], nil
	}
	return nil, err
}

func containsAny(b []byte, subs ...[]byte) bool {
	for _, s := range subs {
		if len(s) == 0 {
			continue
		}
		if bytes.Contains(b, s) {
			return true
		}
	}
	return false
}
