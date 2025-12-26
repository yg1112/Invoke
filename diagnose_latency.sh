#!/bin/bash
# diagnose_latency.sh (Smart Version)

# 读取 Stage 1 发现的端口，默认 3000
PORT=$(cat .target_port 2>/dev/null || echo "3000")

echo "🔍 Stage 3: Testing Latency on Port $PORT..."
echo "---------------------------------------------------"

# --trace-time: 显示时间戳 (精确到微秒)
# --max-time 15: 防止测试卡死
curl -v --trace-time --max-time 15 "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Ping"}],
    "stream": true
  }' 2>&1 | grep -E "HTTP/1.1 200|^{|Trying|Connected"

echo "---------------------------------------------------"
echo "✅ Checkpoint: Look at the timestamp diff between 'Connected' and 'HTTP/1.1 200'"

