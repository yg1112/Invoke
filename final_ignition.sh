#!/bin/bash
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔥 FINAL IGNITION - 隐形桥最终验收"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: Build
echo "📦 Step 1: Building App..."
swift build
if [ $? -ne 0 ]; then
    echo "❌ Build failed"
    exit 1
fi
echo "✅ Build complete"
echo ""

# Step 2: Start App in background
echo "🚀 Step 2: Starting App..."
.build/debug/Invoke > /tmp/fetch_final_test.log 2>&1 &
APP_PID=$!
echo "   App PID: $APP_PID"
echo "   Logs: /tmp/fetch_final_test.log"
echo ""

# Step 3: Wait for server startup
echo "⏳ Step 3: Waiting for server (5 seconds)..."
sleep 5

# Check if port is listening
if ! lsof -ti:3000 > /dev/null 2>&1; then
    echo "❌ Port 3000 not listening"
    echo "   Check logs: tail -f /tmp/fetch_final_test.log"
    kill $APP_PID 2>/dev/null
    exit 1
fi
echo "✅ Port 3000 is listening"
echo ""

# Step 4: Test connectivity
echo "🔌 Step 4: Testing connectivity..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Sending: 'hi' (stream: true)"
echo ""

RESPONSE=$(curl -s --max-time 10 -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hi"}],"stream":true}' 2>&1)

echo "$RESPONSE" | head -20
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if response contains SSE data
if echo "$RESPONSE" | grep -q "data:"; then
    echo "✅ Connectivity test PASSED"
    echo "   Server is responding with SSE format"
    SUCCESS=true
else
    echo "⚠️  Server responded but format may be incorrect"
    echo "   Expected: data: {...}"
    SUCCESS=false
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 FINAL STATUS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "App Status: Running (PID: $APP_PID)"
echo "Server Status: Listening on port 3000"
echo "Connectivity: $([ "$SUCCESS" = true ] && echo '✅ PASS' || echo '⚠️  CHECK LOGS')"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 NEXT STEPS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. 在 Fetch App 窗口中登录 Google 账号（等待🟢绿色状态）"
echo ""
echo "2. 登录完成后，运行完整流式测试："
echo "   ./test_iron_round1_manual.sh"
echo ""
echo "3. 查看实时日志（可选）："
echo "   tail -f /tmp/fetch_final_test.log"
echo ""
echo "4. 停止 App："
echo "   kill $APP_PID"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Keep running (don't kill app)
echo ""
echo "✋ App is still running in background for your testing"
echo "   Press Ctrl+C to stop this script (App will continue)"
echo ""
read -p "Press Enter to stop the app and exit..."

# Cleanup
kill $APP_PID 2>/dev/null
echo "🛑 App stopped"
exit 0
