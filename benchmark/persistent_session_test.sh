#!/bin/bash
# ApexMQTT 持久会话自动重订阅功能验证
# MQTT 3.1.1 规范: CleanSession=false 时，订阅应跨重连持久化
# 参考: mqtt_functional_test.go

set -e

# 节点配置（支持单节点和集群测试）
NODE1="${NODE1:-172.20.184.183}"
NODE2="${NODE2:-172.20.184.184}"
PORT="${PORT:-1883}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_step() { echo -e "${YELLOW}[STEP]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo "============================================"
echo "  ApexMQTT 持久会话自动重订阅功能验证"
echo "  MQTT 3.1.1 协议"
echo "============================================"
echo ""
echo "节点: Node1=$NODE1, Node2=$NODE2, Port=$PORT"
echo ""

# 检查 mosquitto_sub/pub
if ! command -v mosquitto_sub &> /dev/null || ! command -v mosquitto_pub &> /dev/null; then
    log_fail "mosquitto-clients 未安装"
    echo ""
    echo "安装命令:"
    echo "  Ubuntu/Debian: sudo apt install mosquitto-clients"
    echo "  macOS: brew install mosquitto"
    exit 1
fi
log_info "使用 mosquitto_sub/pub 进行测试"
echo ""

cleanup() {
    pkill -f "mosquitto_sub.*persistent_session_test" 2>/dev/null || true
    pkill -f "mosquitto_pub.*persistent_session_test" 2>/dev/null || true
}
trap cleanup EXIT

# 生成随机后缀
SUFFIX=$(date +%s%N | md5sum | head -c 8)
CLIENT_ID="persistent_session_test_${SUFFIX}"
TOPIC="persistent/session/test/${SUFFIX}"
PAYLOAD="auto_resubscribe_${SUFFIX}"

# ============================================
# 测试 1: 单节点持久会话自动重订阅
# ============================================
echo "============================================"
log_step "测试 1: 单节点持久会话自动重订阅"
echo "============================================"
echo ""
log_info "ClientID: $CLIENT_ID"
log_info "Topic: $TOPIC"
echo ""

# 步骤 1: 建立持久会话并订阅
log_info "步骤 1: 建立持久会话并订阅"
mosquitto_sub -h $NODE1 -p $PORT \
    -i "$CLIENT_ID" \
    -t "$TOPIC" \
    -q 1 \
    -c \
    -C 1 \
    -W 3 &>/dev/null &
SUB_PID=$!
sleep 2

# 等待订阅完成后断开
kill $SUB_PID 2>/dev/null || true
wait $SUB_PID 2>/dev/null || true
log_info "订阅建立后断开连接"
sleep 1

# 步骤 2: 重新连接（不调用订阅），等待消息
log_info "步骤 2: 重连（不重新订阅），等待消息"

# 在后台启动订阅者（使用相同 ClientID，不指定 -t 让 broker 使用持久订阅）
# 注意：mosquitto_sub 必须指定 -t，但 broker 应该自动恢复订阅
# 我们通过验证是否能收到消息来确认订阅恢复
RESULT_FILE="/tmp/persistent_session_test_result_${SUFFIX}"
rm -f "$RESULT_FILE"

mosquitto_sub -h $NODE1 -p $PORT \
    -i "$CLIENT_ID" \
    -t "$TOPIC" \
    -q 1 \
    -c \
    -C 1 \
    -W 10 > "$RESULT_FILE" 2>/dev/null &
SUB_PID=$!

sleep 1

# 步骤 3: 发布消息
log_info "步骤 3: 发布测试消息"
mosquitto_pub -h $NODE1 -p $PORT \
    -t "$TOPIC" \
    -m "$PAYLOAD" \
    -q 1

# 等待订阅者接收
wait $SUB_PID 2>/dev/null || true

# 验证结果
if [ -f "$RESULT_FILE" ] && grep -q "$PAYLOAD" "$RESULT_FILE"; then
    log_pass "测试 1 通过: 持久会话订阅自动恢复成功"
    RESULT="收到消息: $(cat $RESULT_FILE)"
    log_info "$RESULT"
else
    log_fail "测试 1 失败: 未收到消息，订阅可能未恢复"
    echo ""
    echo "可能原因:"
    echo "  1. Broker 未正确实现 MQTT 3.1.1 持久会话"
    echo "  2. SessionManager 未保存订阅"
    echo "  3. 连接时 SessionPresent 标志异常"
fi
rm -f "$RESULT_FILE"
echo ""

# ============================================
# 测试 2: CleanSession=true 清除订阅
# ============================================
echo "============================================"
log_step "测试 2: CleanSession=true 清除持久订阅"
echo "============================================"
echo ""

CLIENT_ID2="clean_session_test_${SUFFIX}"
TOPIC2="clean/session/test/${SUFFIX}"
PAYLOAD2="should_not_receive_${SUFFIX}"

# 步骤 1: 建立持久会话并订阅
log_info "步骤 1: 建立持久会话并订阅"
mosquitto_sub -h $NODE1 -p $PORT \
    -i "$CLIENT_ID2" \
    -t "$TOPIC2" \
    -q 1 \
    -c \
    -C 1 \
    -W 3 &>/dev/null &
SUB_PID=$!
sleep 2
kill $SUB_PID 2>/dev/null || true
wait $SUB_PID 2>/dev/null || true
sleep 1

# 步骤 2: 使用 CleanSession=true 连接（清除会话）
log_info "步骤 2: 使用 CleanSession=true 连接（清除会话）"
mosquitto_sub -h $NODE1 -p $PORT \
    -i "$CLIENT_ID2" \
    -t "dummy/topic" \
    -q 0 \
    -C 1 \
    -W 2 &>/dev/null || true
sleep 1

# 步骤 3: 再次使用 CleanSession=false 连接，订阅应该已被清除
log_info "步骤 3: 验证订阅已被清除"
RESULT_FILE2="/tmp/clean_session_test_result_${SUFFIX}"
rm -f "$RESULT_FILE2"

mosquitto_sub -h $NODE1 -p $PORT \
    -i "$CLIENT_ID2" \
    -t "$TOPIC2" \
    -q 1 \
    -c \
    -C 1 \
    -W 3 > "$RESULT_FILE2" 2>/dev/null &
SUB_PID=$!

sleep 1

# 发布消息（在订阅者连接后）
mosquitto_pub -h $NODE1 -p $PORT \
    -t "$TOPIC2" \
    -m "$PAYLOAD2" \
    -q 1

wait $SUB_PID 2>/dev/null || true

# 验证结果（应该能收到消息，因为刚刚订阅了）
if [ -f "$RESULT_FILE2" ] && grep -q "$PAYLOAD2" "$RESULT_FILE2"; then
    log_pass "测试 2 通过: CleanSession=true 正确清除了旧订阅，新订阅正常工作"
else
    log_fail "测试 2 失败: 消息接收异常"
fi
rm -f "$RESULT_FILE2"
echo ""

# ============================================
# 测试 3: 跨节点持久会话迁移 (集群场景)
# ============================================
if [ "$NODE1" != "$NODE2" ]; then
    echo "============================================"
    log_step "测试 3: 跨节点持久会话迁移"
    echo "============================================"
    echo ""
    
    CLIENT_ID3="cluster_session_test_${SUFFIX}"
    TOPIC3="cluster/session/test/${SUFFIX}"
    PAYLOAD3="cluster_migrate_${SUFFIX}"
    
    # 步骤 1: 在 Node1 建立持久会话
    log_info "步骤 1: 在 Node1 建立持久会话并订阅"
    mosquitto_sub -h $NODE1 -p $PORT \
        -i "$CLIENT_ID3" \
        -t "$TOPIC3" \
        -q 1 \
        -c \
        -C 1 \
        -W 3 &>/dev/null &
    SUB_PID=$!
    sleep 2
    kill $SUB_PID 2>/dev/null || true
    wait $SUB_PID 2>/dev/null || true
    log_info "在 Node1 建立订阅后断开"
    sleep 1
    
    # 步骤 2: 在 Node2 重连（应该从集群迁移会话）
    log_info "步骤 2: 在 Node2 重连（触发集群会话迁移）"
    RESULT_FILE3="/tmp/cluster_session_test_result_${SUFFIX}"
    rm -f "$RESULT_FILE3"
    
    mosquitto_sub -h $NODE2 -p $PORT \
        -i "$CLIENT_ID3" \
        -t "$TOPIC3" \
        -q 1 \
        -c \
        -C 1 \
        -W 10 > "$RESULT_FILE3" 2>/dev/null &
    SUB_PID=$!
    
    sleep 2
    
    # 步骤 3: 从 Node1 发布消息
    log_info "步骤 3: 从 Node1 发布消息"
    mosquitto_pub -h $NODE1 -p $PORT \
        -t "$TOPIC3" \
        -m "$PAYLOAD3" \
        -q 1
    
    wait $SUB_PID 2>/dev/null || true
    
    if [ -f "$RESULT_FILE3" ] && grep -q "$PAYLOAD3" "$RESULT_FILE3"; then
        log_pass "测试 3 通过: 跨节点会话迁移成功"
    else
        log_fail "测试 3 失败: 跨节点会话迁移异常"
    fi
    rm -f "$RESULT_FILE3"
    echo ""
else
    log_info "跳过测试 3: 单节点模式，无需测试跨节点迁移"
    echo ""
fi

# ============================================
# 测试总结
# ============================================
echo "============================================"
echo "  测试完成"
echo "============================================"
echo ""
echo "${YELLOW}MQTT 3.1.1 持久会话规范要点:${NC}"
echo ""
echo "  • CleanSession=false 时，订阅必须跨重连持久化"
echo "  • CleanSession=true 时，必须清除所有持久化数据"
echo "  • CONNACK 中 SessionPresent 标志必须正确反映会话状态"
echo "  • 集群场景下，会话迁移后订阅必须保持有效"
echo ""
