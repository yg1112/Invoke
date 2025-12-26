#!/bin/bash
echo "🕵️‍♂️ Stage 1: Searching for Local API Server..."

# 1. 检查 App 进程是否存在
PROCESS=$(pgrep -f "Fetch")
if [ -z "$PROCESS" ]; then
    echo "❌ CRITICAL: Fetch App is NOT running!"
    echo "👉 Action: Please Build & Run the App in Xcode first."
    exit 1
else
    echo "✅ Fetch App is running (PID: $PROCESS)"
fi

# 2. 扫描端口 3000-3010 寻找监听者
FOUND_PORT=""
for port in {3000..3010}; do
    # 使用 lsof 检查端口 (macOS 通用)
    if lsof -i :$port -P | grep -q "LISTEN"; then
        FOUND_PORT=$port
        echo "✅ FOUND Active Server on Port: $FOUND_PORT"
        break
    fi
done

if [ -z "$FOUND_PORT" ]; then
    echo "❌ Process is running but NO Port (3000-3010) is open."
    echo "👉 Analysis: Server might have failed to startListener() or is stuck initializing."
    exit 1
else
    echo "🎯 Target Acquired: http://127.0.0.1:$FOUND_PORT"
    # 将端口写入临时文件供后续脚本使用
    echo "$FOUND_PORT" > .target_port
fi

