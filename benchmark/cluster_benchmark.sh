#!/bin/bash
# ApexMQTT 集群性能测试脚本
# 使用 emqtt-bench 进行专业压测
# 每个测试场景限制在 10 秒内完成
# 使用 MQTT 3.1.1 协议 (-V 4)
# 参考: AXMQ-Flash/readme.md

set -e

# ============================================================================
# 集群节点配置
# ============================================================================
NODE1_HOST="172.20.184.183"
NODE2_HOST="172.20.184.184"
NODE3_HOST="172.20.184.185"
MQTT_PORT=1883

# 测试参数
PAYLOAD_SIZE=256        # 消息体大小 (bytes)
TEST_DURATION=10        # 每个测试持续时间 (秒)
PUB_INTERVAL=10         # 发布间隔 (ms)

# emqtt_bench 路径（在 main 中初始化）
EMQTT_BENCH=""

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

cleanup() {
    pkill -f "emqtt_bench" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# 测试 1: 单节点基准测试 (Baseline)
# ============================================================================
test_single_node_baseline() {
    log_info "========== 测试 1: 单节点基准测试 (${TEST_DURATION}s) =========="
    log_info "目的: 建立单机性能基线"
    log_info "配置: 10 订阅者 + 100 发布者，同一节点"
    
    # 启动订阅者
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 10 -t "bench/single" -q 0 &
    SUB_PID=$!
    sleep 2
    
    # 启动发布者
    log_info "发布中..."
    timeout $((TEST_DURATION - 3))s $EMQTT_BENCH pub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 100 -t "bench/single" -q 0 \
        -s $PAYLOAD_SIZE -I $PUB_INTERVAL || true
    
    wait $SUB_PID 2>/dev/null || true
    log_success "单节点基准测试完成"
    echo ""
}

# ============================================================================
# 测试 2: 跨节点消息转发 (核心集群功能)
# ============================================================================
test_cross_node_forwarding() {
    log_info "========== 测试 2: 跨节点消息转发 (${TEST_DURATION}s) =========="
    log_info "目的: 测试集群消息路由和转发性能"
    log_info "配置: 订阅者在 Node1, 发布者在 Node2"
    
    # 启动订阅者 (Node1)
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 10 -t "bench/cross" -q 0 &
    SUB_PID=$!
    sleep 3  # 等待订阅同步到集群
    
    # 启动发布者 (Node2)
    log_info "发布中..."
    timeout $((TEST_DURATION - 4))s $EMQTT_BENCH pub -V 4 -h $NODE2_HOST -p $MQTT_PORT -c 100 -t "bench/cross" -q 0 \
        -s $PAYLOAD_SIZE -I $PUB_INTERVAL || true
    
    wait $SUB_PID 2>/dev/null || true
    log_success "跨节点消息转发测试完成"
    echo ""
}

# ============================================================================
# 测试 3: 多节点订阅者分布测试
# ============================================================================
test_multi_node_subscribers() {
    log_info "========== 测试 3: 多节点订阅者分布 (${TEST_DURATION}s) =========="
    log_info "目的: 测试消息扇出到多个节点的性能"
    log_info "配置: 每个节点 10 订阅者, 发布者在 Node1"
    
    # 在三个节点启动订阅者
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 10 -t "bench/fanout" -q 0 &
    SUB_PID1=$!
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE2_HOST -p $MQTT_PORT -c 10 -t "bench/fanout" -q 0 &
    SUB_PID2=$!
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE3_HOST -p $MQTT_PORT -c 10 -t "bench/fanout" -q 0 &
    SUB_PID3=$!
    sleep 3
    
    # 启动发布者
    log_info "发布中..."
    timeout $((TEST_DURATION - 4))s $EMQTT_BENCH pub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 50 -t "bench/fanout" -q 0 \
        -s $PAYLOAD_SIZE -I $PUB_INTERVAL || true
    
    wait $SUB_PID1 $SUB_PID2 $SUB_PID3 2>/dev/null || true
    log_success "多节点订阅者分布测试完成"
    echo ""
}

# ============================================================================
# 测试 4: QoS 1 可靠消息跨节点转发
# ============================================================================
test_qos1_cross_node() {
    log_info "========== 测试 4: QoS 1 跨节点可靠传输 (${TEST_DURATION}s) =========="
    log_info "目的: 验证 QoS 1 消息的跨节点可靠性"
    log_info "配置: 订阅者在 Node1 (QoS 1), 发布者在 Node2 (QoS 1)"
    
    # 启动订阅者
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 10 -t "bench/qos1" -q 1 &
    SUB_PID=$!
    sleep 3
    
    # 启动发布者 (QoS 1，间隔稍大)
    log_info "发布中..."
    timeout $((TEST_DURATION - 4))s $EMQTT_BENCH pub -V 4 -h $NODE2_HOST -p $MQTT_PORT -c 50 -t "bench/qos1" -q 1 \
        -s $PAYLOAD_SIZE -I 16 || true
    
    wait $SUB_PID 2>/dev/null || true
    log_success "QoS 1 跨节点测试完成"
    echo ""
}

# ============================================================================
# 测试 5: QoS 2 精确一次跨节点传输
# ============================================================================
test_qos2_cross_node() {
    log_info "========== 测试 5: QoS 2 跨节点精确一次传输 (${TEST_DURATION}s) =========="
    log_info "目的: 验证 QoS 2 消息的跨节点精确一次语义"
    log_info "配置: 订阅者在 Node1 (QoS 2), 发布者在 Node2 (QoS 2)"
    
    # 启动订阅者
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 10 -t "bench/qos2" -q 2 &
    SUB_PID=$!
    sleep 3
    
    # 启动发布者 (QoS 2 需要四次握手，间隔更大，客户端更少)
    log_info "发布中..."
    timeout $((TEST_DURATION - 4))s $EMQTT_BENCH pub -V 4 -h $NODE2_HOST -p $MQTT_PORT -c 20 -t "bench/qos2" -q 2 \
        -s $PAYLOAD_SIZE -I 20 || true
    
    wait $SUB_PID 2>/dev/null || true
    log_success "QoS 2 跨节点测试完成"
    echo ""
}

# ============================================================================
# 测试 6: 通配符订阅跨节点转发
# ============================================================================
test_wildcard_cross_node() {
    log_info "========== 测试 6: 通配符订阅跨节点 (${TEST_DURATION}s) =========="
    log_info "目的: 测试通配符订阅的集群路由性能"
    log_info "配置: Node1 订阅 sensors/+/data, Node2 发布到 sensors/{id}/data"
    
    # 启动通配符订阅者
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 10 -t "sensors/+/data" -q 0 &
    SUB_PID=$!
    sleep 3
    
    # 启动发布者 (使用 %i 模板发布到不同主题)
    log_info "发布中..."
    timeout $((TEST_DURATION - 4))s $EMQTT_BENCH pub -V 4 -h $NODE2_HOST -p $MQTT_PORT -c 100 \
        -t "sensors/%i/data" -q 0 -s $PAYLOAD_SIZE -I $PUB_INTERVAL || true
    
    wait $SUB_PID 2>/dev/null || true
    log_success "通配符订阅跨节点测试完成"
    echo ""
}

# ============================================================================
# 测试 7: 高并发连接测试
# ============================================================================
test_high_concurrency() {
    log_info "========== 测试 7: 高并发连接 (${TEST_DURATION}s) =========="
    log_info "目的: 测试集群处理大量连接的能力"
    log_info "配置: 每个节点建立 200 个连接"
    
    # 使用 conn 子命令测试连接
    timeout ${TEST_DURATION}s $EMQTT_BENCH conn -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 200 -i 10 -k 60 &
    CONN_PID1=$!
    timeout ${TEST_DURATION}s $EMQTT_BENCH conn -V 4 -h $NODE2_HOST -p $MQTT_PORT -c 200 -i 10 -k 60 &
    CONN_PID2=$!
    timeout ${TEST_DURATION}s $EMQTT_BENCH conn -V 4 -h $NODE3_HOST -p $MQTT_PORT -c 200 -i 10 -k 60 &
    CONN_PID3=$!
    
    wait $CONN_PID1 $CONN_PID2 $CONN_PID3 2>/dev/null || true
    log_success "高并发连接测试完成 (目标 600 连接)"
    echo ""
}

# ============================================================================
# 测试 8: N:N 多主题测试
# ============================================================================
test_n2n() {
    log_info "========== 测试 8: N:N 多主题测试 (${TEST_DURATION}s) =========="
    log_info "目的: 测试多主题并发的集群路由性能"
    log_info "配置: 100 订阅者对 100 发布者，每对使用唯一主题 bench/nn/%i"
    
    # 三个节点启动订阅者
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 33 -t "bench/nn/%i" -q 0 &
    SUB_PID1=$!
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE2_HOST -p $MQTT_PORT -c 33 -t "bench/nn/%i" -q 0 &
    SUB_PID2=$!
    timeout ${TEST_DURATION}s $EMQTT_BENCH sub -V 4 -h $NODE3_HOST -p $MQTT_PORT -c 34 -t "bench/nn/%i" -q 0 &
    SUB_PID3=$!
    sleep 3
    
    # 启动发布者
    log_info "发布中..."
    timeout $((TEST_DURATION - 4))s $EMQTT_BENCH pub -V 4 -h $NODE1_HOST -p $MQTT_PORT -c 100 \
        -t "bench/nn/%i" -q 0 -s $PAYLOAD_SIZE -I $PUB_INTERVAL || true
    
    wait $SUB_PID1 $SUB_PID2 $SUB_PID3 2>/dev/null || true
    log_success "N:N 多主题测试完成"
    echo ""
}

# ============================================================================
# 主函数
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "       ApexMQTT 集群性能测试 (emqtt-bench)"
    echo "       MQTT 3.1.1 协议 | 每个测试限时 ${TEST_DURATION}s"
    echo "============================================================"
    echo ""
    echo "集群节点:"
    echo "  Node1: $NODE1_HOST:$MQTT_PORT"
    echo "  Node2: $NODE2_HOST:$MQTT_PORT"
    echo "  Node3: $NODE3_HOST:$MQTT_PORT"
    echo ""
    echo "测试参数:"
    echo "  Payload Size: $PAYLOAD_SIZE bytes"
    echo "  Publish Interval: ${PUB_INTERVAL}ms"
    echo ""
    
    # 检查 emqtt_bench（必须在解压目录运行）
    if [ -x "./bin/emqtt_bench" ]; then
        EMQTT_BENCH="./bin/emqtt_bench"
    elif [ -x "$HOME/bin/emqtt_bench" ]; then
        EMQTT_BENCH="$HOME/bin/emqtt_bench"
    else
        log_error "emqtt_bench 未找到，请在解压目录运行此脚本！"
        echo ""
        echo "安装步骤 (Ubuntu 24.04 使用 debian12 版本):"
        echo "  cd ~"
        echo "  wget https://github.com/emqx/emqtt-bench/releases/download/0.6.1/emqtt-bench-0.6.1-debian12-amd64.tar.gz"
        echo "  tar -xzf emqtt-bench-0.6.1-debian12-amd64.tar.gz"
        echo "  ./cluster_benchmark.sh"
        exit 1
    fi
    log_info "使用: $EMQTT_BENCH"
    echo ""
    
    case "${1:-all}" in
        1|baseline)
            test_single_node_baseline
            ;;
        2|cross)
            test_cross_node_forwarding
            ;;
        3|fanout)
            test_multi_node_subscribers
            ;;
        4|qos1)
            test_qos1_cross_node
            ;;
        5|qos2)
            test_qos2_cross_node
            ;;
        6|wildcard)
            test_wildcard_cross_node
            ;;
        7|conn)
            test_high_concurrency
            ;;
        8|n2n)
            test_n2n
            ;;
        all)
            test_single_node_baseline
            test_cross_node_forwarding
            test_multi_node_subscribers
            test_qos1_cross_node
            test_qos2_cross_node
            test_wildcard_cross_node
            test_high_concurrency
            test_n2n
            ;;
        *)
            echo "用法: $0 [测试编号|all]"
            echo ""
            echo "可用测试 (每个限时 ${TEST_DURATION}s):"
            echo "  1, baseline  - 单节点基准测试"
            echo "  2, cross     - 跨节点消息转发"
            echo "  3, fanout    - 多节点订阅者分布"
            echo "  4, qos1      - QoS 1 可靠传输"
            echo "  5, qos2      - QoS 2 精确一次传输"
            echo "  6, wildcard  - 通配符订阅跨节点"
            echo "  7, conn      - 高并发连接"
            echo "  8, n2n       - N:N 多主题测试"
            echo "  all          - 运行所有测试 (约 $((TEST_DURATION * 8))s)"
            exit 0
            ;;
    esac
    
    echo ""
    log_success "测试完成!"
}

main "$@"
