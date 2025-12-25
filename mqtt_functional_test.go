package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

type brokerEndpoint struct {
	name string
	url  string
}

func getEnv(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func getEnvInt(t *testing.T, key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			t.Fatalf("invalid %s=%q", key, v)
		}
		return n
	}
	return def
}

func endpointsFromEnv() []brokerEndpoint {
	tcp := getEnv("MQTT_TCP_URL", "tcp://cp7.xbyct.net:1883")
	ws := getEnv("MQTT_WS_URL", "ws://cp7.xbyct.net:8083")
	return []brokerEndpoint{
		{name: "tcp", url: tcp},
		{name: "ws", url: ws},
	}
}

func randSuffix() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:]) + strconv.FormatInt(time.Now().UnixNano(), 36)
}

func topicWithSuffix(prefix string) string {
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return prefix + randSuffix()
}

func newClientOptions(brokerURL, clientID string, clean bool) *mqtt.ClientOptions {
	opts := mqtt.NewClientOptions()
	opts.AddBroker(brokerURL)
	opts.SetClientID(clientID)
	opts.SetCleanSession(clean)
	opts.SetConnectTimeout(5 * time.Second)
	opts.SetAutoReconnect(false)
	return opts
}

func mustConnect(t *testing.T, c mqtt.Client, timeout time.Duration) {
	t.Helper()
	tok := c.Connect()
	if !tok.WaitTimeout(timeout) || tok.Error() != nil {
		t.Fatalf("connect error: %v", tok.Error())
	}
}

func mustWaitToken(t *testing.T, tok mqtt.Token, timeout time.Duration, what string) {
	t.Helper()
	if !tok.WaitTimeout(timeout) {
		t.Fatalf("%s timeout", what)
	}
	if tok.Error() != nil {
		t.Fatalf("%s error: %v", what, tok.Error())
	}
}

func createClient(broker, id string, clean bool) mqtt.Client {
	return mqtt.NewClient(newClientOptions(broker, id, clean))
}

func waitTimeout(wg *sync.WaitGroup, timeout time.Duration) bool {
	c := make(chan struct{})
	go func() {
		wg.Wait()
		close(c)
	}()
	select {
	case <-c:
		return false
	case <-time.After(timeout):
		return true
	}
}

func TestMQTT_Functional_Full(t *testing.T) {
	eps := endpointsFromEnv()

	for _, ep := range eps {
		ep := ep
		t.Run(ep.name, func(t *testing.T) {
			t.Run("ConnectAndDisconnect", func(t *testing.T) {
				c := createClient(ep.url, ep.name+"_basic_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				c.Disconnect(250)
			})

			t.Run("PubSub_QoS0", func(t *testing.T) {
				c := createClient(ep.url, ep.name+"_qos0_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				topic := topicWithSuffix("cp7/test/qos0")
				payload := "hello qos0"
				wg := sync.WaitGroup{}
				wg.Add(1)
				var once sync.Once

				mustWaitToken(t, c.Subscribe(topic, 0, func(client mqtt.Client, msg mqtt.Message) {
					if string(msg.Payload()) == payload {
						once.Do(func() { wg.Done() })
					}
				}), 5*time.Second, "subscribe")

				c.Publish(topic, 0, false, payload)
				if waitTimeout(&wg, 3*time.Second) {
					t.Fatal("Timed out waiting for QoS0 message")
				}
			})

			t.Run("PubSub_QoS1", func(t *testing.T) {
				c := createClient(ep.url, ep.name+"_qos1_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				topic := topicWithSuffix("cp7/test/qos1")
				payload := "hello qos1"
				wg := sync.WaitGroup{}
				wg.Add(1)
				var once sync.Once

				mustWaitToken(t, c.Subscribe(topic, 1, func(client mqtt.Client, msg mqtt.Message) {
					if string(msg.Payload()) == payload {
						once.Do(func() { wg.Done() })
					}
				}), 5*time.Second, "subscribe")

				mustWaitToken(t, c.Publish(topic, 1, false, payload), 10*time.Second, "publish")
				if waitTimeout(&wg, 10*time.Second) {
					t.Fatal("Timed out waiting for QoS1 message")
				}
			})

			t.Run("PubSub_QoS2", func(t *testing.T) {
				c := createClient(ep.url, ep.name+"_qos2_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				topic := topicWithSuffix("cp7/test/qos2")
				payload := "hello qos2"
				wg := sync.WaitGroup{}
				wg.Add(1)
				var once sync.Once

				mustWaitToken(t, c.Subscribe(topic, 2, func(client mqtt.Client, msg mqtt.Message) {
					if string(msg.Payload()) == payload {
						once.Do(func() { wg.Done() })
					}
				}), 5*time.Second, "subscribe")

				mustWaitToken(t, c.Publish(topic, 2, false, payload), 20*time.Second, "publish")
				if waitTimeout(&wg, 20*time.Second) {
					t.Fatal("Timed out waiting for QoS2 message")
				}
			})

			t.Run("Wildcard_Plus", func(t *testing.T) {
				c := createClient(ep.url, ep.name+"_wcplus_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				wg := sync.WaitGroup{}
				wg.Add(1)
				var once sync.Once

				mustWaitToken(t, c.Subscribe("a/+/c", 0, func(client mqtt.Client, msg mqtt.Message) {
					if msg.Topic() == "a/b/c" {
						once.Do(func() { wg.Done() })
					}
				}), 5*time.Second, "subscribe")

				c.Publish("a/b/c", 0, false, "match")
				if waitTimeout(&wg, 3*time.Second) {
					t.Fatal("Wildcard + failed")
				}
			})

			t.Run("Wildcard_Hash", func(t *testing.T) {
				c := createClient(ep.url, ep.name+"_wchash_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				wg := sync.WaitGroup{}
				wg.Add(2)
				var m1, m2 sync.Once

				mustWaitToken(t, c.Subscribe("a/#", 0, func(client mqtt.Client, msg mqtt.Message) {
					if msg.Topic() == "a/b/c" {
						m1.Do(func() { wg.Done() })
					} else if msg.Topic() == "a/d" {
						m2.Do(func() { wg.Done() })
					}
				}), 5*time.Second, "subscribe")

				c.Publish("a/b/c", 0, false, "match1")
				c.Publish("a/d", 0, false, "match2")
				if waitTimeout(&wg, 3*time.Second) {
					t.Fatal("Wildcard # failed")
				}
			})

			t.Run("Unsubscribe", func(t *testing.T) {
				c := createClient(ep.url, ep.name+"_unsub_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				topic := topicWithSuffix("cp7/test/unsub")
				wg := sync.WaitGroup{}
				wg.Add(1)

				mustWaitToken(t, c.Subscribe(topic, 1, func(client mqtt.Client, msg mqtt.Message) {
					wg.Done()
				}), 5*time.Second, "subscribe")

				mustWaitToken(t, c.Unsubscribe(topic), 5*time.Second, "unsubscribe")
				mustWaitToken(t, c.Publish(topic, 1, false, "should_not_arrive"), 10*time.Second, "publish")

				if !waitTimeout(&wg, 1*time.Second) {
					t.Fatal("Received message after unsubscribe")
				}
			})

			t.Run("Retain", func(t *testing.T) {
				topic := topicWithSuffix("cp7/test/retain")
				payload := "retained_" + randSuffix()

				pub := createClient(ep.url, ep.name+"_retain_pub_"+randSuffix(), true)
				mustConnect(t, pub, 5*time.Second)
				defer pub.Disconnect(250)

				// 确保测试结束时清理保留消息
				defer func() {
					clr := createClient(ep.url, ep.name+"_retain_clr_"+randSuffix(), true)
					if tok := clr.Connect(); tok.Wait() && tok.Error() == nil {
						clr.Publish(topic, 1, true, []byte{}).Wait()
						clr.Disconnect(250)
					}
				}()

				mustWaitToken(t, pub.Publish(topic, 1, true, payload), 10*time.Second, "publish retain")

				sub := createClient(ep.url, ep.name+"_retain_sub_"+randSuffix(), true)
				mustConnect(t, sub, 5*time.Second)
				defer sub.Disconnect(250)

				wg := sync.WaitGroup{}
				wg.Add(1)
				var once sync.Once
				mustWaitToken(t, sub.Subscribe(topic, 1, func(client mqtt.Client, msg mqtt.Message) {
					if string(msg.Payload()) == payload {
						once.Do(func() { wg.Done() })
					}
				}), 5*time.Second, "subscribe")

				if waitTimeout(&wg, 10*time.Second) {
					t.Fatal("Retain message not received")
				}
			})

			t.Run("SharedSubscription_Basic", func(t *testing.T) {
				topic := topicWithSuffix("cp7/test/shared_basic")
				filter := "$share/g_basic/" + topic

				c1 := createClient(ep.url, ep.name+"_share1_"+randSuffix(), true)
				c2 := createClient(ep.url, ep.name+"_share2_"+randSuffix(), true)
				mustConnect(t, c1, 5*time.Second)
				mustConnect(t, c2, 5*time.Second)
				defer c1.Disconnect(250)
				defer c2.Disconnect(250)

				received := make(chan string, 10)
				handler := func(client mqtt.Client, msg mqtt.Message) {
					received <- string(msg.Payload())
				}

				mustWaitToken(t, c1.Subscribe(filter, 1, handler), 5*time.Second, "subscribe c1")
				mustWaitToken(t, c2.Subscribe(filter, 1, handler), 5*time.Second, "subscribe c2")

				pub := createClient(ep.url, ep.name+"_sharepub_"+randSuffix(), true)
				mustConnect(t, pub, 5*time.Second)
				defer pub.Disconnect(250)

				// Publish 4 messages, they should be distributed
				for i := 0; i < 4; i++ {
					pub.Publish(topic, 1, false, "msg_"+strconv.Itoa(i))
				}

				count := 0
				timeout := time.After(5 * time.Second)
				for count < 4 {
					select {
					case <-received:
						count++
					case <-timeout:
						t.Fatalf("Timed out waiting for shared messages, got %d/4", count)
					}
				}
			})

			t.Run("Wildcard_Mix_Exact", func(t *testing.T) {
				// 验证通配符路径和精确路径共存时的正确性
				base := "mix/" + randSuffix()
				exactTopic := base + "/a/b"
				wildcardTopic := base + "/+/b"

				cSub := createClient(ep.url, ep.name+"_mixsub_"+randSuffix(), true)
				mustConnect(t, cSub, 5*time.Second)
				defer cSub.Disconnect(250)

				var count atomic.Int32
				handler := func(client mqtt.Client, msg mqtt.Message) {
					count.Add(1)
				}

				mustWaitToken(t, cSub.Subscribe(exactTopic, 0, handler), 5*time.Second, "sub exact")
				mustWaitToken(t, cSub.Subscribe(wildcardTopic, 0, handler), 5*time.Second, "sub wildcard")

				pub := createClient(ep.url, ep.name+"_mixpub_"+randSuffix(), true)
				mustConnect(t, pub, 5*time.Second)
				defer pub.Disconnect(250)

				pub.Publish(exactTopic, 0, false, "hi")

				// 即使有多个匹配订阅，Broker 去重后客户端只应收到 1 条消息。
				// 但 Paho 库内部会对收到的 1 条消息匹配 2 个 handler（如果订阅了两个匹配的主题）。
				// 最终结果取决于客户端行为，我们这里验证至少收到且不 panic。
				time.Sleep(1 * time.Second)
				if count.Load() == 0 {
					t.Fatal("Failed to receive any messages")
				}
			})

			t.Run("Overlapping_Subscription_QoS", func(t *testing.T) {
				// 协议规范 3.3.4: 重叠订阅时发送单条消息，且 QoS 为所有匹配中的最高值
				topic := topicWithSuffix("overlap/" + randSuffix())
				wildcard := "overlap/#"

				cSub := createClient(ep.url, ep.name+"_ovsub_"+randSuffix(), true)
				mustConnect(t, cSub, 5*time.Second)
				defer cSub.Disconnect(250)

				var count atomic.Int32
				var receivedQoS byte
				wg := sync.WaitGroup{}
				wg.Add(1)

				// 订阅 QoS 0 和 QoS 2
				mustWaitToken(t, cSub.Subscribe(topic, 0, nil), 5*time.Second, "sub qos0")
				mustWaitToken(t, cSub.Subscribe(wildcard, 2, func(client mqtt.Client, msg mqtt.Message) {
					count.Add(1)
					receivedQoS = byte(msg.Qos())
					wg.Done()
				}), 5*time.Second, "sub qos2")

				pub := createClient(ep.url, ep.name+"_ovpub_"+randSuffix(), true)
				mustConnect(t, pub, 5*time.Second)
				defer pub.Disconnect(250)

				// 发布 QoS 2 消息
				pub.Publish(topic, 2, false, "hi")

				if waitTimeout(&wg, 5*time.Second) {
					t.Fatal("Failed to receive overlapped message")
				}

				if count.Load() != 1 {
					t.Fatalf("Expected 1 message (de-duplicated), but got %d", count.Load())
				}
				if receivedQoS != 2 {
					t.Fatalf("Expected QoS 2 (highest), but got %d", receivedQoS)
				}
			})

			t.Run("Invalid_Topic_Filters", func(t *testing.T) {
				// 验证非法主题过滤器被拒绝 (SUBACK 0x80)
				c := createClient(ep.url, ep.name+"_invsub_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				// 真正非法的过滤器 (根据协议 Section 4.7)
				testFilters := []string{
					"a/#/c", // # 不在末尾
					"a/b#",  // # 没跟着层级分隔符
					"a/b+",  // + 没跟着层级分隔符
				}

				for _, filter := range testFilters {
					tok := c.Subscribe(filter, 0, nil)
					tok.WaitTimeout(2 * time.Second)

					// 检查 SUBACK 返回的结果码是否为 0x80 (Failure)
					if st, ok := tok.(*mqtt.SubscribeToken); ok {
						for f, qos := range st.Result() {
							if f == filter && qos != 0x80 {
								t.Errorf("Broker should have returned 0x80 for invalid filter %s, but got %d", filter, qos)
							}
						}
					} else if tok.Error() == nil {
						t.Errorf("Broker should have rejected invalid filter: %s", filter)
					}
				}
			})

			t.Run("Retain_Wildcard_Match", func(t *testing.T) {
				// 验证通配符订阅能匹配多个已存在的保留消息
				base := "retain_wc/" + randSuffix()
				t1 := base + "/a"
				t2 := base + "/b"
				payload := "val"

				pub := createClient(ep.url, ep.name+"_rtpub_"+randSuffix(), true)
				mustConnect(t, pub, 5*time.Second)
				defer pub.Disconnect(250)

				// 清理函数：确保测试结束时删除保留消息
				defer func() {
					clr := createClient(ep.url, ep.name+"_rtclr_"+randSuffix(), true)
					if tok := clr.Connect(); tok.Wait() && tok.Error() == nil {
						clr.Publish(t1, 1, true, []byte{}).Wait()
						clr.Publish(t2, 1, true, []byte{}).Wait()
						clr.Disconnect(250)
					}
				}()

				mustWaitToken(t, pub.Publish(t1, 1, true, payload), 5*time.Second, "pub1")
				mustWaitToken(t, pub.Publish(t2, 1, true, payload), 5*time.Second, "pub2")

				sub := createClient(ep.url, ep.name+"_rtsub_"+randSuffix(), true)
				mustConnect(t, sub, 5*time.Second)
				defer sub.Disconnect(250)

				var count atomic.Int32
				wg := sync.WaitGroup{}
				wg.Add(2)

				mustWaitToken(t, sub.Subscribe(base+"/#", 1, func(client mqtt.Client, msg mqtt.Message) {
					count.Add(1)
					wg.Done()
				}), 5*time.Second, "sub")

				if waitTimeout(&wg, 5*time.Second) {
					t.Fatalf("Failed to receive all retained messages via wildcard, got %d", count.Load())
				}
			})

			t.Run("SystemTopic_NoCrossMatch", func(t *testing.T) {
				// 验证 $SYS 主题不会被普通的 # 或 + 匹配到
				cSub := createClient(ep.url, ep.name+"_syssub_"+randSuffix(), true)
				mustConnect(t, cSub, 5*time.Second)
				defer cSub.Disconnect(250)

				// 增大缓冲区以防止保留消息过多导致处理 goroutine 阻塞，从而引起 SUBACK 超时
				received := make(chan string, 1000)
				mustWaitToken(t, cSub.Subscribe("#", 0, func(client mqtt.Client, msg mqtt.Message) {
					select {
					case received <- msg.Topic():
					default:
						// 如果缓冲区满了，直接忽略，避免阻塞 Paho 内部协程
					}
				}), 10*time.Second, "sub hash")

				pub := createClient(ep.url, ep.name+"_syspub_"+randSuffix(), true)
				mustConnect(t, pub, 5*time.Second)
				defer pub.Disconnect(250)

				// 发布到 $SYS 主题
				pub.Publish("$SYS/broker/version", 0, false, "1.0")

				// 循环读取，直到超时。如果期间收到了以 $SYS 开头的消息，则说明漏洞存在
				timeout := time.After(2 * time.Second)
				for {
					select {
					case topic := <-received:
						if strings.HasPrefix(topic, "$") {
							t.Fatalf("Normal wildcard # should NOT match $SYS topic, but got: %s", topic)
						}
						// 忽略非 $SYS 的杂讯消息（如 will/test）
					case <-timeout:
						return // 成功：没有收到 $SYS 消息
					}
				}
			})

			t.Run("SystemTopic_Functionality", func(t *testing.T) {
				// 验证 $SYS 主题能够正确返回数据 (依赖于 Retain 机制)
				c := createClient(ep.url, ep.name+"_sysfunc_"+randSuffix(), true)
				mustConnect(t, c, 5*time.Second)
				defer c.Disconnect(250)

				topics := []string{
					"$SYS/broker/version",
					"$SYS/broker/uptime",
					"$SYS/broker/clients/connected",
					"$SYS/broker/clients/total",
					"$SYS/broker/messages/received",
					"$SYS/broker/messages/sent",
					"$SYS/broker/subscriptions/count",
				}

				for _, tc := range topics {
					wg := sync.WaitGroup{}
					wg.Add(1)
					var once sync.Once
					var payload string
					mustWaitToken(t, c.Subscribe(tc, 0, func(client mqtt.Client, msg mqtt.Message) {
						payload = string(msg.Payload())
						once.Do(func() { wg.Done() })
					}), 5*time.Second, "sub "+tc)

					if waitTimeout(&wg, 5*time.Second) {
						t.Errorf("Timed out waiting for %s", tc)
					} else if payload == "" {
						t.Errorf("Received empty payload for %s", tc)
					}
					_ = c.Unsubscribe(tc)
				}
			})
		})
	}

	// TCP-only: persistent session behavior
	t.Run("TCP_Only", func(t *testing.T) {
		tcp := eps[0].url

		t.Run("ClientID_Conflict_Kick", func(t *testing.T) {
			id := "conflict_" + randSuffix()
			c1 := createClient(tcp, id, true)
			mustConnect(t, c1, 5*time.Second)

			c2 := createClient(tcp, id, true)
			mustConnect(t, c2, 5*time.Second)

			time.Sleep(500 * time.Millisecond)
			if c1.IsConnected() {
				t.Fatal("C1 should have been kicked by C2")
			}
			c2.Disconnect(250)
		})

		t.Run("CleanSession_False_Persistence", func(t *testing.T) {
			clientID := "persist_" + randSuffix()
			topic := topicWithSuffix("cp7/test/session")
			payload := "offline_" + randSuffix()

			c1 := createClient(tcp, clientID, false)
			mustConnect(t, c1, 5*time.Second)
			mustWaitToken(t, c1.Subscribe(topic, 1, nil), 5*time.Second, "subscribe")
			c1.Disconnect(250)

			cPub := createClient(tcp, "publisher_"+randSuffix(), true)
			mustConnect(t, cPub, 5*time.Second)
			mustWaitToken(t, cPub.Publish(topic, 1, false, payload), 10*time.Second, "publish")
			cPub.Disconnect(250)

			wg := sync.WaitGroup{}
			wg.Add(1)
			opts2 := newClientOptions(tcp, clientID, false)
			opts2.SetDefaultPublishHandler(func(client mqtt.Client, msg mqtt.Message) {
				if string(msg.Payload()) == payload {
					wg.Done()
				}
			})
			c2 := mqtt.NewClient(opts2)
			mustConnect(t, c2, 5*time.Second)
			defer c2.Disconnect(250)

			if waitTimeout(&wg, 10*time.Second) {
				t.Fatal("Offline message not received via persistent session")
			}
		})

		t.Run("LWT_Abnormal_Disconnect", func(t *testing.T) {
			// 验证异常断开时遗嘱消息的触发 (协议 Section 3.1.2.5)
			willTopic := "will/status/" + randSuffix()
			willPayload := "offline"

			// 1. 订阅遗嘱主题
			sub := createClient(tcp, "lwt_sub_"+randSuffix(), true)
			mustConnect(t, sub, 5*time.Second)
			defer sub.Disconnect(250)

			wg := sync.WaitGroup{}
			wg.Add(1)
			mustWaitToken(t, sub.Subscribe(willTopic, 1, func(client mqtt.Client, msg mqtt.Message) {
				if string(msg.Payload()) == willPayload {
					wg.Done()
				}
			}), 5*time.Second, "sub")

			// 2. 模拟一个崩溃的客户端：连接并发送 Will，然后强制关闭 TCP
			addr := tcpAddrFromMQTTURL(tcp)
			conn, err := tcpDial(addr, 5*time.Second)
			if err != nil {
				t.Fatalf("dial error: %v", err)
			}

			// 构造 CONNECT 包 (包含 Will)
			cid := "crash_client_" + randSuffix()

			var pkt []byte
			// 协议名 "MQTT" (0x00 0x04 'M' 'Q' 'T' 'T')
			pkt = append(pkt, 0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0x06, 0x00, 0x3C)
			// Payload: ClientID, WillTopic, WillMessage
			pkt = append(pkt, uint8(len(cid)>>8), uint8(len(cid)&0xFF))
			pkt = append(pkt, []byte(cid)...)
			pkt = append(pkt, uint8(len(willTopic)>>8), uint8(len(willTopic)&0xFF))
			pkt = append(pkt, []byte(willTopic)...)
			pkt = append(pkt, uint8(len(willPayload)>>8), uint8(len(willPayload)&0xFF))
			pkt = append(pkt, []byte(willPayload)...)

			// 写入 CONNECT (带剩余长度，假设 < 127)
			_, _ = conn.Write(append([]byte{0x10, uint8(len(pkt))}, pkt...))

			// 等待 CONNACK
			resp, err := mustReadSome(conn, 2*time.Second)
			if err != nil || len(resp) < 4 || resp[3] != 0x00 {
				t.Fatalf("CONNACK failed or timeout: %v (resp: %v)", err, resp)
			}

			// 3. 核心步骤：直接物理关闭 TCP 连接，不发 DISCONNECT 报文
			conn.Close()

			// 4. 验证遗嘱是否被分发
			if waitTimeout(&wg, 10*time.Second) {
				t.Fatal("LWT message not received after abnormal disconnect")
			}
		})

		t.Run("LWT_Normal_Disconnect", func(t *testing.T) {
			// 验证正常断开连接时遗嘱消息不应触发 (协议 Section 3.1.2.5)
			willTopic := "will/normal/" + randSuffix()
			willPayload := "should_not_see_this"

			// 1. 订阅遗嘱主题
			sub := createClient(tcp, "lwt_normal_sub_"+randSuffix(), true)
			mustConnect(t, sub, 5*time.Second)
			defer sub.Disconnect(250)

			received := atomic.Bool{}
			mustWaitToken(t, sub.Subscribe(willTopic, 1, func(client mqtt.Client, msg mqtt.Message) {
				received.Store(true)
			}), 5*time.Second, "sub")

			// 2. 正常连接并设置遗嘱，然后正常断开
			opts := newClientOptions(tcp, "normal_will_client_"+randSuffix(), true)
			opts.SetWill(willTopic, willPayload, 1, false)
			c := mqtt.NewClient(opts)
			mustConnect(t, c, 5*time.Second)

			// 发送 DISCONNECT 报文
			c.Disconnect(250)

			// 3. 等待一段时间，验证没有收到遗嘱消息
			time.Sleep(2 * time.Second)
			if received.Load() {
				t.Fatal("LWT message received after normal DISCONNECT, protocol violation")
			}
		})

		t.Run("LWT_Normal_Disconnect_Immediate_Close", func(t *testing.T) {
			// 极端测试：使用原生 TCP 发送 DISCONNECT 后立即物理关闭连接
			// 用于验证 pollio 优先级和 OnDisconnect 缓冲区排空逻辑
			willTopic := "will/race/" + randSuffix()
			willPayload := "should_not_see_this"

			// 1. 订阅遗嘱主题
			sub := createClient(tcp, "lwt_race_sub_"+randSuffix(), true)
			mustConnect(t, sub, 5*time.Second)
			defer sub.Disconnect(250)

			received := atomic.Bool{}
			mustWaitToken(t, sub.Subscribe(willTopic, 1, func(client mqtt.Client, msg mqtt.Message) {
				received.Store(true)
			}), 5*time.Second, "sub")

			// 2. 通过原生 TCP 模拟极限行为
			addr := tcpAddrFromMQTTURL(tcp)
			conn, err := tcpDial(addr, 5*time.Second)
			if err != nil {
				t.Fatalf("dial error: %v", err)
			}

			cid := "race_client_" + randSuffix()
			// CONNECT 报文 (带 Will)
			var pkt []byte
			pkt = append(pkt, 0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0x06, 0x00, 0x3C)
			pkt = append(pkt, uint8(len(cid)>>8), uint8(len(cid)&0xFF))
			pkt = append(pkt, []byte(cid)...)
			pkt = append(pkt, uint8(len(willTopic)>>8), uint8(len(willTopic)&0xFF))
			pkt = append(pkt, []byte(willTopic)...)
			pkt = append(pkt, uint8(len(willPayload)>>8), uint8(len(willPayload)&0xFF))
			pkt = append(pkt, []byte(willPayload)...)
			_, _ = conn.Write(append([]byte{0x10, uint8(len(pkt))}, pkt...))

			// 等待 CONNACK 确保服务端已解析
			_, _ = mustReadSome(conn, 2*time.Second)

			// 3. 极限操作：发送 DISCONNECT (0xE0, 0x00) 并立即 Close
			_, _ = conn.Write([]byte{0xE0, 0x00})
			conn.Close() // 立即物理断开，模拟网络事件与数据包同时到达

			// 4. 验证遗嘱不应被触发
			time.Sleep(2 * time.Second)
			if received.Load() {
				t.Fatal("LWT message triggered despite DISCONNECT sent before socket close (Race condition failed)")
			}
		})

		t.Run("Session_Recovery_QoS2", func(t *testing.T) {
			// 验证 QoS 2 在 CleanSession=0 时的会话恢复能力
			clientID := "q2persist_" + randSuffix()
			topic := topicWithSuffix("cp7/test/q2persist")
			payload := "q2_offline_" + randSuffix()

			// 1. 建立持久会话并订阅
			c1 := createClient(tcp, clientID, false)
			mustConnect(t, c1, 5*time.Second)
			mustWaitToken(t, c1.Subscribe(topic, 2, nil), 5*time.Second, "subscribe")
			c1.Disconnect(250)

			// 2. 发送 QoS 2 离线消息
			cPub := createClient(tcp, "q2publisher_"+randSuffix(), true)
			mustConnect(t, cPub, 5*time.Second)
			mustWaitToken(t, cPub.Publish(topic, 2, false, payload), 10*time.Second, "publish q2")
			cPub.Disconnect(250)

			// 3. 重新连接并验证接收
			wg := sync.WaitGroup{}
			wg.Add(1)
			opts2 := newClientOptions(tcp, clientID, false)
			opts2.SetDefaultPublishHandler(func(client mqtt.Client, msg mqtt.Message) {
				if string(msg.Payload()) == payload && msg.Qos() == 2 {
					wg.Done()
				}
			})
			c2 := mqtt.NewClient(opts2)
			mustConnect(t, c2, 5*time.Second)
			defer c2.Disconnect(250)

			if waitTimeout(&wg, 15*time.Second) {
				t.Fatal("Offline QoS 2 message not recovered")
			}
		})
	})

	// Delivery minimum (TCP+WS). Default is 64KB; tune with MQTT_DELIVER_MIN.
	//t.Run("Payload_Delivery_Min", func(t *testing.T) {
	//	minBytes := getEnvInt(t, "MQTT_DELIVER_MIN", 64*1024)
	//	topic := topicWithSuffix("cp7/test/deliver_min")
	//
	//	for _, ep := range eps {
	//		ep := ep
	//		t.Run(ep.name, func(t *testing.T) {
	//			deliverOnce := func(size int) (bool, string) {
	//				subLost := make(chan error, 1)
	//				subOpts := newClientOptions(ep.url, ep.name+"_dsub_"+randSuffix(), true)
	//				subOpts.SetConnectionLostHandler(func(client mqtt.Client, err error) {
	//					select {
	//					case subLost <- err:
	//					default:
	//					}
	//				})
	//				sub := mqtt.NewClient(subOpts)
	//				mustConnect(t, sub, 5*time.Second)
	//				defer sub.Disconnect(250)
	//
	//				wg := sync.WaitGroup{}
	//				wg.Add(1)
	//				gotLenCh := make(chan int, 1)
	//				var once sync.Once
	//				mustWaitToken(t, sub.Subscribe(topic, 1, func(client mqtt.Client, msg mqtt.Message) {
	//					once.Do(func() {
	//						gotLenCh <- len(msg.Payload())
	//						wg.Done()
	//					})
	//				}), 5*time.Second, "subscribe")
	//
	//				pub := createClient(ep.url, ep.name+"_dpub_"+randSuffix(), true)
	//				mustConnect(t, pub, 5*time.Second)
	//				defer pub.Disconnect(250)
	//
	//				payload := make([]byte, size)
	//				for i := range payload {
	//					payload[i] = byte(i)
	//				}
	//				tok := pub.Publish(topic, 1, false, payload)
	//				if !tok.WaitTimeout(30*time.Second) || tok.Error() != nil {
	//					if tok.Error() != nil {
	//						return false, "publish error: " + tok.Error().Error()
	//					}
	//					return false, "publish timeout"
	//				}
	//
	//				if waitTimeout(&wg, 30*time.Second) {
	//					select {
	//					case err := <-subLost:
	//						return false, "subscriber lost connection: " + err.Error()
	//					default:
	//					}
	//					return false, "subscriber did not receive message"
	//				}
	//				got := <-gotLenCh
	//				if got != size {
	//					return false, "payload length mismatch"
	//				}
	//				return true, ""
	//			}
	//
	//			ok, why := deliverOnce(minBytes)
	//			if ok {
	//				return
	//			}
	//
	//			// Probe downwards with fresh connections to avoid contaminating state.
	//			candidates := []int{minBytes / 2, minBytes / 4, minBytes / 8, 64 * 1024, 32 * 1024, 16 * 1024, 8 * 1024}
	//			best := 0
	//			for _, sz := range candidates {
	//				if sz <= 0 {
	//					continue
	//				}
	//				ok2, _ := deliverOnce(sz)
	//				if ok2 {
	//					best = sz
	//					break
	//				}
	//			}
	//			t.Fatalf("payload %d not delivered on %s (%s). Max deliverable appears <= %d bytes. Tune TCP listener write-buffer/backpressure if you require larger delivery.",
	//				minBytes, ep.name, why, best)
	//		})
	//	}
	//})

	//// Max packet size policy (TCP). Default max is 1MB.
	//t.Run("MaxPacketSize", func(t *testing.T) {
	//	maxPacket := getEnvInt(t, "MQTT_MAX_PACKET", 1024*1024)
	//	tcp := eps[0].url
	//
	//	t.Run("QoS1_Accept_JustUnder", func(t *testing.T) {
	//		topic := "cp7/test/maxpkt"
	//		pub := createClient(tcp, "maxpkt_pub_"+randSuffix(), true)
	//		mustConnect(t, pub, 5*time.Second)
	//		defer pub.Disconnect(250)
	//
	//		// Binary search the largest payload size that completes QoS1 publish.
	//		buf := make([]byte, maxPacket)
	//		for i := range buf {
	//			buf[i] = byte(i)
	//		}
	//
	//		lo, hi := 0, len(buf)
	//		best := 0
	//		for lo <= hi {
	//			mid := (lo + hi) / 2
	//			tok := pub.Publish(topic, 1, false, buf[:mid])
	//			if tok.WaitTimeout(5*time.Second) && tok.Error() == nil {
	//				best = mid
	//				lo = mid + 1
	//			} else {
	//				hi = mid - 1
	//			}
	//		}
	//		if best == 0 {
	//			t.Fatal("cannot publish any payload under max packet size (unexpected)")
	//		}
	//	})
	//
	//	t.Run("OverLimit_Rejected_OptIn", func(t *testing.T) {
	//		if os.Getenv("MQTT_TEST_OVERLIMIT") != "1" {
	//			t.Skip("set MQTT_TEST_OVERLIMIT=1 to run over-limit test (may affect IP blocking policies)")
	//		}
	//		pub := createClient(tcp, "overlimit_pub_"+randSuffix(), true)
	//		mustConnect(t, pub, 5*time.Second)
	//		defer pub.Disconnect(250)
	//
	//		over := make([]byte, maxPacket+2048)
	//		tok := pub.Publish("cp7/test/overlimit", 1, false, over)
	//		if tok.WaitTimeout(10*time.Second) && tok.Error() == nil {
	//			t.Fatal("expected publish rejection for oversize packet")
	//		}
	//	})
	//})

	// Protocol validation / failure-mode tests (raw TCP, no paho)
	// 注释掉可能会导致 IP 被封禁的非法协议测试
	/*
		t.Run("Protocol_InvalidPackets_TCP", func(t *testing.T) {
			tcpURL := eps[0].url
			addr := tcpAddrFromMQTTURL(tcpURL)

			t.Run("Invalid_CONNECT_RemainingLengthVarint", func(t *testing.T) {
				conn, err := tcpDial(addr, 3*time.Second)
				if err != nil {
					t.Fatalf("dial error: %v", err)
				}
				defer conn.Close()

				// CONNECT fixed header with malformed Remaining Length (5 bytes, MQTT allows max 4)
				// 0x10 + 0xFF 0xFF 0xFF 0xFF 0x7F
				_, _ = conn.Write([]byte{0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F})

				b, err := mustReadSome(conn, 2*time.Second)
				// We accept either close (err) or an error response (rare). Key is: no hang.
				if err == nil && len(b) > 0 {
					_ = b
				}
			})

			t.Run("Invalid_CONNECT_GarbageBody", func(t *testing.T) {
				conn, err := tcpDial(addr, 3*time.Second)
				if err != nil {
					t.Fatalf("dial error: %v", err)
				}
				defer conn.Close()

				// CONNECT with Remaining Length 1 but body garbage. Broker should close.
				_, _ = conn.Write([]byte{0x10, 0x01, 0x00})
				_, _ = mustReadSome(conn, 2*time.Second)
			})
		})
	*/

	// Optional: shared subscription distribution (TCP only) - enable with MQTT_STRESS=1
	t.Run("SharedSubscription_OptIn", func(t *testing.T) {
		if os.Getenv("MQTT_STRESS") != "1" {
			t.Skip("set MQTT_STRESS=1 to run shared subscription distribution test")
		}
		tcp := eps[0].url
		topic := topicWithSuffix("cp7/test/shared")
		filter := "$share/g1/" + topic

		c1 := createClient(tcp, "share1_"+randSuffix(), true)
		c2 := createClient(tcp, "share2_"+randSuffix(), true)
		mustConnect(t, c1, 5*time.Second)
		mustConnect(t, c2, 5*time.Second)
		defer c1.Disconnect(250)
		defer c2.Disconnect(250)

		var n1, n2 int
		var mu sync.Mutex
		mustWaitToken(t, c1.Subscribe(filter, 1, func(client mqtt.Client, msg mqtt.Message) {
			mu.Lock()
			n1++
			mu.Unlock()
		}), 5*time.Second, "subscribe")
		mustWaitToken(t, c2.Subscribe(filter, 1, func(client mqtt.Client, msg mqtt.Message) {
			mu.Lock()
			n2++
			mu.Unlock()
		}), 5*time.Second, "subscribe")

		pub := createClient(tcp, "sharepub_"+randSuffix(), true)
		mustConnect(t, pub, 5*time.Second)
		defer pub.Disconnect(250)

		for i := 0; i < 50; i++ {
			mustWaitToken(t, pub.Publish(topic, 1, false, []byte("x")), 5*time.Second, "publish")
		}
		time.Sleep(500 * time.Millisecond)

		mu.Lock()
		a, b := n1, n2
		mu.Unlock()
		if a == 0 || b == 0 {
			t.Fatalf("shared subscription distribution seems broken: n1=%d n2=%d", a, b)
		}
	})
}
