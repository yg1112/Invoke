#!/bin/bash
echo "🚀 Quick Test for Fetch (Invisible Mode)"
echo "========================================"

# 1. 确保 App 在运行
if ! pgrep -x "Fetch" > /dev/null; then
    echo "⚡️ Starting Fetch..."
    open -a Fetch
    sleep 2
else
    echo "✅ Fetch is running."
fi

# 2. 检查端口 (Woz 的检查点)
echo "🔍 Checking Port 3000..."
if lsof -i :3000 > /dev/null; then
    echo "✅ Port 3000 is ACTIVE. The Ear is listening."
else
    echo "❌ Port 3000 is CLOSED. The Server is down."
    exit 1
fi

# 3. 发送真实请求 (Jobs 的体验点)
echo "🧪 Sending a test thought to Gemini..."
# 发送一个简单的 "Hello" 请求
RESPONSE=$(curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.0-flash",
    "messages": [{"role": "user", "content": "Reply with exactly one word: CONNECTED"}]
  }')

echo "📄 Raw Response: $RESPONSE"

if echo "$RESPONSE" | grep -q "CONNECTED"; then
    echo ""
    echo "✅✅✅ SUCCESS: Neural Link Established!"
    echo "🎉 You are ready to run Aider."
else
    echo ""
    echo "⚠️  WARNING: Response received but content unexpected. Check the 'Show Brain' window."
fi
