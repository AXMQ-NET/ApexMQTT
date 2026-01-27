#!/bin/bash
# ApexMQTT 集群快速验证测试
# 每个测试场景限制在 10 秒内完成
# 使用 MQTT 3.1.1 协议 (-V 4)
# 参考: AXMQ-Flash/readme.md

set -e

# 节点配置
NODE1="172.20.184.183"
NODE2="172.20.184.184"
NODE3="172.20.184.185"
PORT=1883

# 测试时间限制（秒）
TEST_DURATION=10

echo "============================================"
echo "  ApexMQTT 集群快速性能验证"
echo "  MQTT 3.1.1 协议 | 每个测试限时 ${TEST_DURATION}s"
echo "============================================"
echo ""
echo "节点: Node1=$NODE1, Node2=$NODE2, Node3=$NODE3"
echo ""

# 检查 emqtt_bench（优先使用本地 bin/ 目录）
EMQTT_BENCH=""
if [ -x "./bin/emqtt_bench" ]; then
    EMQTT_BENCH="./bin/emqtt_bench"
elif [ -x "$HOME/bin/emqtt_bench" ]; then
    EMQTT_BENCH="$HOME/bin/emqtt_bench"
else
    echo "[ERROR] emqtt_bench 未找到"
    echo ""
    echo "请确保在 emqtt-bench 解压目录运行此脚本！"
    echo ""
    echo "安装步骤 (Ubuntu 24.04 使用 debian12 版本):"
    echo "  cd ~"
    echo "  wget https://github.com/emqx/emqtt-bench/releases/download/0.6.1/emqtt-bench-0.6.1-debian12-amd64.tar.gz"
    echo "  tar -xzf emqtt-bench-0.6.1-debian12-amd64.tar.gz"
    echo "  ./quick_test.sh"
    exit 1
fi
echo "使用: $EMQTT_BENCH"

cleanup() {
    pkill -f "emqtt_bench" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================
# 测试 1: QoS 0 跨节点高吞吐测试
# ============================================
echo ""
echo "[1/5] QoS 0 跨节点高吞吐测试"
echo "----------------------------------------"
echo "  订阅者: Node1 x 10"
echo "  发布者: Node2 x 100"
echo "----------------------------------------"

# 启动订阅者 (Node1)
timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1 -p $PORT -c 10 -t "bench/1" -q 0 &
SUB_PID=$!
sleep 2

# 启动发布者 (Node2)
echo "[发布中... ${TEST_DURATION}s]"
timeout $((TEST_DURATION - 3))s $EMQTT_BENCH pub -V 4 -h $NODE2 -p $PORT -c 100 -t "bench/1" -q 0 -s 256 -I 10 || true

wait $SUB_PID 2>/dev/null || true
echo ""

# ============================================
# 测试 2: QoS 1 跨节点可靠传输测试
# ============================================
echo "[2/5] QoS 1 跨节点可靠传输测试"
echo "----------------------------------------"
echo "  订阅者: Node1 x 10"
echo "  发布者: Node2 x 50"
echo "----------------------------------------"

timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1 -p $PORT -c 10 -t "bench/qos1" -q 1 &
SUB_PID=$!
sleep 2

echo "[发布中... ${TEST_DURATION}s]"
timeout $((TEST_DURATION - 3))s $EMQTT_BENCH pub -V 4 -h $NODE2 -p $PORT -c 50 -t "bench/qos1" -q 1 -s 256 -I 16 || true

wait $SUB_PID 2>/dev/null || true
echo ""

# ============================================
# 测试 3: 通配符跨节点测试
# ============================================
echo "[3/5] 通配符订阅跨节点测试"
echo "----------------------------------------"
echo "  订阅者: Node1 订阅 sensors/+/data"
echo "  发布者: Node2 发布到 sensors/{id}/data"
echo "----------------------------------------"

timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1 -p $PORT -c 10 -t "sensors/+/data" -q 0 &
SUB_PID=$!
sleep 2

echo "[发布中... ${TEST_DURATION}s]"
# 使用 %i 模板让每个客户端发布到不同主题
timeout $((TEST_DURATION - 3))s $EMQTT_BENCH pub -V 4 -h $NODE2 -p $PORT -c 100 -t "sensors/%i/data" -q 0 -s 256 -I 10 || true

wait $SUB_PID 2>/dev/null || true
echo ""

# ============================================
# 测试 4: QoS 2 跨节点精确一次传输测试
# ============================================
echo "[4/5] QoS 2 跨节点精确一次传输测试"
echo "----------------------------------------"
echo "  订阅者: Node1 x 10 (QoS 2)"
echo "  发布者: Node2 x 20 (QoS 2)"
echo "----------------------------------------"

timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1 -p $PORT -c 10 -t "bench/qos2" -q 2 &
SUB_PID=$!
sleep 2

echo "[发布中... ${TEST_DURATION}s]"
# QoS 2 需要四次握手，使用更大间隔和更少客户端
timeout $((TEST_DURATION - 3))s $EMQTT_BENCH pub -V 4 -h $NODE2 -p $PORT -c 20 -t "bench/qos2" -q 2 -s 256 -I 20 || true

wait $SUB_PID 2>/dev/null || true
echo ""

# ============================================
# 测试 5: 多节点扇出测试 (N:N)
# ============================================
echo "[5/5] 多节点 N:N 扇出测试"
echo "----------------------------------------"
echo "  订阅者: 三个节点各 30 个 (bench/nn/%i)"
echo "  发布者: Node1 x 90 (bench/nn/%i)"
echo "----------------------------------------"

# 三个节点启动订阅者
timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1 -p $PORT -c 30 -t "bench/nn/%i" -q 0 &
SUB_PID1=$!
timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE2 -p $PORT -c 30 -t "bench/nn/%i" -q 0 &
SUB_PID2=$!
timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE3 -p $PORT -c 30 -t "bench/nn/%i" -q 0 &
SUB_PID3=$!
sleep 2

echo "[发布中... ${TEST_DURATION}s]"
timeout $((TEST_DURATION - 3))s $EMQTT_BENCH pub -V 4 -h $NODE1 -p $PORT -c 90 -t "bench/nn/%i" -q 0 -s 256 -I 10 || true

wait $SUB_PID1 $SUB_PID2 $SUB_PID3 2>/dev/null || true
echo ""

echo "============================================"
echo "  测试完成! (总耗时约 $((TEST_DURATION * 5)) 秒)"
echo "============================================"
echo ""
echo "性能参考 (同机房预期):"
echo "  QoS 0 跨节点: 数万+ msg/s"
echo "  QoS 1 跨节点: 数千+ msg/s"
echo "  QoS 2 跨节点: 数百~千 msg/s (四次握手)"
echo "  通配符转发:   接近 QoS 0 性能"
echo ""
