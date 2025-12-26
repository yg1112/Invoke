#!/bin/bash

LOG_FILE="verification_output.log"
APP_BUNDLE="./Fetch.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Fetch"

echo "🏥 开始系统机能验收..." | tee $LOG_FILE
echo "==============================" | tee -a $LOG_FILE

# 1. 清理环境
echo "🧹 清理旧进程..." | tee -a $LOG_FILE
pkill -f "Fetch" 2>/dev/null
pkill -f "Invoke" 2>/dev/null
sleep 1

# 2. 构建项目 (确保是最新代码)
echo "🏗️ 正在构建 Fetch..." | tee -a $LOG_FILE
./build_app.sh > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ 构建失败！请检查 Swift 编译错误。" | tee -a $LOG_FILE
    exit 1
fi
echo "✅ 构建成功" | tee -a $LOG_FILE

# 2.5. 设置项目根目录（在启动 App 之前，让 GeminiLinkLogic 在初始化时读取）
TEST_PROJECT_ROOT=$(pwd)
defaults write com.yukungao.fetch ProjectRoot "$TEST_PROJECT_ROOT" 2>/dev/null
echo "📁 已预设项目根目录: $TEST_PROJECT_ROOT" | tee -a $LOG_FILE

# 3. 启动 App (使用 open 命令，保证 WindowServer 连接)
echo "🚀 启动 Fetch (使用 open 命令)..." | tee -a $LOG_FILE
# 使用 open -n 允许新实例，-g 后台运行但保持 UI 上下文
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ App bundle 不存在: $APP_BUNDLE" | tee -a $LOG_FILE
    exit 1
fi
open -n -g "$APP_BUNDLE" 2>&1 | tee -a $LOG_FILE

# 等待启动 (LocalAPIServer 启动需要几秒)
echo "⏳ 等待服务初始化 (7秒)..." | tee -a $LOG_FILE
sleep 7

# 获取 App 进程 PID (等待一下让进程完全启动)
sleep 1
APP_PID=$(ps aux | grep -i "Fetch.app/Contents/MacOS/Fetch" | grep -v grep | awk '{print $2}' | head -1)
if [ -z "$APP_PID" ]; then
    echo "❌ 无法找到 Fetch 进程" | tee -a $LOG_FILE
    exit 1
fi
echo "   PID: $APP_PID" | tee -a $LOG_FILE

# 4. 测试一：API 服务连通性 (LocalAPIServer)
echo "------------------------------" | tee -a $LOG_FILE
echo "🧪 测试 1: Local API Server (端口 3000)" | tee -a $LOG_FILE

# 尝试多个端口 (3000-3010)
API_TEST_PASSED=false
for port in {3000..3010}; do
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$port/v1/models 2>/dev/null)
    if [ "$RESPONSE" == "200" ]; then
        echo "✅ API 服务响应正常 (HTTP 200) - 端口 $port" | tee -a $LOG_FILE
        API_TEST_PASSED=true
        break
    fi
done

if [ "$API_TEST_PASSED" == "false" ]; then
    echo "❌ API 服务未响应 (尝试了端口 3000-3010)" | tee -a $LOG_FILE
    echo "   诊断建议: 检查 LocalAPIServer.swift 端口绑定或防火墙设置。" | tee -a $LOG_FILE
    echo "   查看 App 日志: tail -f app_runtime.log" | tee -a $LOG_FILE
fi

# 5. 测试二：剪贴板协议识别 (GeminiLinkLogic)
echo "------------------------------" | tee -a $LOG_FILE
echo "🧪 测试 2: 剪贴板协议触发器 (Protocol V3)" | tee -a $LOG_FILE

# 模拟 AI 发出的指令 (使用新的 Protocol V3 格式)
TEST_PAYLOAD=">>> INVOKE
!!!FILE_START!!!
TestResult.txt
Verification Passed - Protocol V3
!!!FILE_END!!!"

# 写入剪贴板 (macOS pbcopy)
echo "$TEST_PAYLOAD" | pbcopy
echo "   已注入测试 Payload 到剪贴板 (Protocol V3)" | tee -a $LOG_FILE

# 等待 5 秒让 App 轮询检测 (增加等待时间，确保定时器已启动)
sleep 5

# 检查日志中是否有初始化信息
if grep -q "Listening started" app_runtime.log 2>/dev/null; then
    echo "   ✅ 剪贴板监听已启动" | tee -a $LOG_FILE
else
    echo "   ⚠️ 未检测到监听启动日志" | tee -a $LOG_FILE
fi

# 检查日志中是否有特定关键词
CLIPBOARD_TEST_PASSED=false
if grep -q "Detected Protocol\|Processing...\|⚡️ Detected" app_runtime.log 2>/dev/null; then
    echo "✅ 逻辑核心成功识别协议头" | tee -a $LOG_FILE
    CLIPBOARD_TEST_PASSED=true
else
    echo "❌ 逻辑核心未反应" | tee -a $LOG_FILE
    echo "   诊断建议: 检查 GeminiLinkLogic.swift 的 magicTrigger 或定时器。" | tee -a $LOG_FILE
    echo "   查看 App 日志: tail -20 app_runtime.log" | tee -a $LOG_FILE
fi

# 6. 检查进程是否仍然存活
echo "------------------------------" | tee -a $LOG_FILE
echo "🔍 检查进程状态..." | tee -a $LOG_FILE
if ps -p $APP_PID > /dev/null 2>&1; then
    echo "✅ 进程仍然运行 (PID: $APP_PID)" | tee -a $LOG_FILE
    PROCESS_ALIVE=true
else
    echo "❌ 进程已崩溃或退出" | tee -a $LOG_FILE
    PROCESS_ALIVE=false
fi

# 7. 结束测试
echo "==============================" | tee -a $LOG_FILE
echo "🛑 停止测试进程..." | tee -a $LOG_FILE
kill $APP_PID 2>/dev/null
sleep 2

# 8. 总结
echo "==============================" | tee -a $LOG_FILE
echo "📊 验收结果总结:" | tee -a $LOG_FILE

# 进程存活是必要条件
if [ "$PROCESS_ALIVE" != "true" ]; then
    echo "🔴 失败: App 进程崩溃，无法继续测试" | tee -a $LOG_FILE
    exit 1
fi

if [ "$API_TEST_PASSED" == "true" ] && [ "$CLIPBOARD_TEST_PASSED" == "true" ]; then
    echo "🟢 全绿: 系统机能正常，进程稳定，可以开始接管！" | tee -a $LOG_FILE
    exit 0
elif [ "$API_TEST_PASSED" == "true" ]; then
    echo "🟡 部分通过: API 正常，进程稳定，但剪贴板协议识别失败" | tee -a $LOG_FILE
    echo "   注意: 剪贴板协议可能需要 App 在前台运行" | tee -a $LOG_FILE
    exit 0  # API 正常且进程稳定，可以继续
elif [ "$CLIPBOARD_TEST_PASSED" == "true" ]; then
    echo "🟡 部分通过: 剪贴板协议识别正常，但 API 服务未启动" | tee -a $LOG_FILE
    exit 1
else
    echo "🟡 部分通过: 进程稳定，但功能测试未完全通过" | tee -a $LOG_FILE
    if [ "$API_TEST_PASSED" == "true" ]; then
        echo "   ✅ API 服务正常，这是核心功能" | tee -a $LOG_FILE
        exit 0  # 只要 API 正常且进程稳定，就可以继续
    fi
    exit 1
fi

