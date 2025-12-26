#!/bin/bash
echo "🧹 1. 强制关闭 Fetch..."
pkill -9 Fetch
sleep 2

echo "🚀 2. 启动 Fetch (请在 10秒内完成手动登录确认)..."
open -n ./Fetch.app

echo "⏳ 3. 等待 App 初始化 (15秒)..."
sleep 15 

echo "🧪 4. 发送 API 测试请求..."
# 发送一个让 Gemini 生成代码的请求
curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.0-flash",
    "messages": [{"role": "user", "content": "Create a file named verify_bridge.txt with content: BRIDGE_WORKING"}]
  }' > /tmp/api_response.json
  
echo "📄 API 响应:"
cat /tmp/api_response.json

echo ""
echo "🔍 5. 检查埋点日志 (验证链路)..."
# 查找关键的"分流"日志
log show --predicate 'process == "Fetch"' --last 1m --style compact | grep -E "⚡️|Bridging|processResponse"

echo ""
echo "📂 6. 检查文件是否生成..."
if [ -f "verify_bridge.txt" ]; then
    echo "✅✅✅ SUCCESS: 文件已生成！全链路打通！"
else
    echo "❌ FAILURE: 文件未生成。"
fi

