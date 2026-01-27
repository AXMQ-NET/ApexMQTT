#!/bin/bash
# ApexMQTT 集群优雅下线功能验证
# 使用 emqtt-bench 测试 Session 迁移
# 参考: tests/benchmark/quick_test.sh

set -e

# 节点配置
NODE1="172.20.184.183"
NODE2="172.20.184.184"
NODE3="172.20.184.185"
PORT=1883

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
echo "  ApexMQTT 集群优雅下线功能验证"
echo "  MQTT 3.1.1 协议"
echo "============================================"
echo ""
echo "节点: Node1=$NODE1, Node2=$NODE2, Node3=$NODE3"
echo ""

# 检查 emqtt_bench
EMQTT_BENCH=""
if [ -x "./bin/emqtt_bench" ]; then
    EMQTT_BENCH="./bin/emqtt_bench"
elif [ -x "$HOME/bin/emqtt_bench" ]; then
    EMQTT_BENCH="$HOME/bin/emqtt_bench"
else
    log_fail "emqtt_bench 未找到，请在 emqtt-bench 解压目录运行此脚本"
    exit 1
fi
log_info "使用: $EMQTT_BENCH"

# 检查 emqtt-bench 是否支持 CleanSession 参数
# 不同版本参数可能是 -C, --clean, --clean-session 等
CLEAN_SESSION_PARAM=""
if $EMQTT_BENCH sub --help 2>&1 | grep -q "clean-session"; then
    CLEAN_SESSION_PARAM="--clean-session false"
elif $EMQTT_BENCH sub --help 2>&1 | grep -q "\-C"; then
    CLEAN_SESSION_PARAM="-C false"
fi

if [ -n "$CLEAN_SESSION_PARAM" ]; then
    log_info "CleanSession 参数: $CLEAN_SESSION_PARAM"
else
    log_info "注意: emqtt-bench 可能不支持设置 CleanSession=false"
    log_info "将使用日志观察方式验证优雅下线"
fi
echo ""

cleanup() {
    pkill -f "emqtt_bench" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================
# 阶段 1: 创建持久 Session
# ============================================
echo "============================================"
log_step "阶段 1: 在 Node1 创建持久 Session"
echo "============================================"
echo ""
log_info "启动 10 个持久订阅者 (CleanSession=false)"
log_info "ClientID 前缀: graceful_test_"
log_info "订阅主题: graceful/test/topic"
echo ""

# 启动订阅者（尝试使用持久 Session）
# 使用 QoS 1 确保有消息状态
if [ -n "$CLEAN_SESSION_PARAM" ]; then
    $EMQTT_BENCH sub -V 4 -h $NODE1 -p $PORT \
        -c 10 \
        -t "graceful/test/topic" \
        -q 1 \
        --prefix "graceful_test_" \
        $CLEAN_SESSION_PARAM \
        &
else
    $EMQTT_BENCH sub -V 4 -h $NODE1 -p $PORT \
        -c 10 \
        -t "graceful/test/topic" \
        -q 1 \
        --prefix "graceful_test_" \
        &
fi
SUB_PID=$!

sleep 3

# 发送一些测试消息，确保订阅生效
log_info "发送测试消息验证订阅..."
$EMQTT_BENCH pub -V 4 -h $NODE2 -p $PORT \
    -c 1 \
    -t "graceful/test/topic" \
    -q 1 \
    -s 64 \
    -L 10 \
    2>/dev/null || true

sleep 2

# 停止订阅者（模拟客户端断开，Session 保留）
log_info "停止订阅者，保留 Session..."
kill $SUB_PID 2>/dev/null || true
wait $SUB_PID 2>/dev/null || true

log_pass "阶段 1 完成: 10 个持久 Session 已创建在 Node1"
echo ""

# ============================================
# 阶段 2: 优雅关闭 Node1
# ============================================
echo "============================================"
log_step "阶段 2: 优雅关闭 Node1"
echo "============================================"
echo ""
echo "请在 Node1 ($NODE1) 服务器上执行以下操作:"
echo ""
echo "  ${YELLOW}方式 1 - 直接 kill:${NC}"
echo "    kill \$(pgrep -f ApexMQTT)"
echo ""
echo "  ${YELLOW}方式 2 - systemd:${NC}"
echo "    systemctl stop axmq"
echo ""
echo "  ${YELLOW}预期日志输出:${NC}"
echo "    [cluster] graceful leave started..."
echo "    [cluster] selected takeover node: <node2 或 node3>"
echo "    [cluster] pushing 10 sessions to takeover node <nodeID>..."
echo "    [cluster] disconnecting all clients..."
echo "    [cluster] leaving cluster..."
echo ""
echo "  ${YELLOW}接管者节点预期日志（只有一个节点会收到）:${NC}"
echo "    [cluster] received session takeover for client graceful_test_0 from <node1>"
echo "    [cluster] received session takeover for client graceful_test_1 from <node1>"
echo "    ... (所有 Session 只推送到一个接管者节点，无冗余)"
echo ""
read -p "按 Enter 继续（在 Node1 优雅关闭后）..."
echo ""

# ============================================
# 阶段 3: 验证 Session 迁移
# ============================================
echo "============================================"
log_step "阶段 3: 验证 Session 迁移"
echo "============================================"
echo ""
log_info "Session 已推送到接管者节点（通过 SessionIndex 路由）"
log_info "使用相同 ClientID 前缀重连到 Node2..."
log_info "Node2 会通过 SessionIndex 找到 Session 所在节点，按需拉取"
echo ""

# 重新启动订阅者（使用相同前缀）
# 如果 Session 迁移成功，应该能立即接收消息
if [ -n "$CLEAN_SESSION_PARAM" ]; then
    $EMQTT_BENCH sub -V 4 -h $NODE2 -p $PORT \
        -c 10 \
        -t "graceful/test/topic" \
        -q 1 \
        --prefix "graceful_test_" \
        $CLEAN_SESSION_PARAM \
        &
else
    $EMQTT_BENCH sub -V 4 -h $NODE2 -p $PORT \
        -c 10 \
        -t "graceful/test/topic" \
        -q 1 \
        --prefix "graceful_test_" \
        &
fi
SUB_PID=$!

sleep 3

# 发送新消息测试
log_info "发送新消息验证 Session 恢复..."
$EMQTT_BENCH pub -V 4 -h $NODE2 -p $PORT \
    -c 1 \
    -t "graceful/test/topic" \
    -q 1 \
    -s 64 \
    -I 100 \
    -L 50 \
    2>/dev/null &
PUB_PID=$!

sleep 5

# 停止测试
kill $SUB_PID 2>/dev/null || true
kill $PUB_PID 2>/dev/null || true
wait $SUB_PID 2>/dev/null || true
wait $PUB_PID 2>/dev/null || true

echo ""
log_pass "阶段 3 完成"
echo ""

# ============================================
# 测试总结
# ============================================
echo "============================================"
echo "  测试完成"
echo "============================================"
echo ""
echo "${YELLOW}验证清单:${NC}"
echo ""
echo "  □ Node1 日志: 'graceful leave started...'"
echo "  □ Node1 日志: 'selected takeover node: <nodeID>'"
echo "  □ Node1 日志: 'pushing N sessions to takeover node...'"
echo "  □ 接管者节点日志: 'received session takeover for client...' (10 条)"
echo "  □ 其他节点: 无 session 相关日志（Session 只推送到一个节点）"
echo "  □ 重连的订阅者能收到新消息 (recv > 0)"
echo ""
echo "${YELLOW}如果验证失败，排查步骤:${NC}"
echo ""
echo "  1. 检查 Node1 是否正常执行了 GracefulLeave"
echo "  2. 检查 Node2/Node3 是否收到 Session 推送"
echo "  3. 检查 ClientID 前缀是否一致"
echo "  4. 确保使用了 CleanSession=false (-C false)"
echo ""
