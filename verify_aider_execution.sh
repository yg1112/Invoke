#!/bin/bash

# 0. 配置环境
export OPENAI_API_BASE=http://127.0.0.1:3000/v1
export OPENAI_API_KEY=any-key-works
# 使用正确的模型名称格式
export AIDER_MODEL=gemini-2.0-flash

LOG_FILE="aider_verification.log"
TEST_FILE="neuro_link_test.txt"

echo "🧠 开始 Aider 神经链路贯通测试..." | tee $LOG_FILE
echo "==============================" | tee -a $LOG_FILE

# 1. 准备测试靶场
echo "Testing connectivity..." > $TEST_FILE
echo "   [1/4] 测试文件已创建: $TEST_FILE" | tee -a $LOG_FILE

# 2. 检查 Aider 是否安装
if ! command -v aider &> /dev/null; then
    echo "❌ 未检测到 aider 命令。正在尝试安装..." | tee -a $LOG_FILE
    pip3 install aider-chat 2>&1 | tee -a $LOG_FILE
    if ! command -v aider &> /dev/null; then
        echo "❌ 安装失败，请确保 python/pip 环境正常。" | tee -a $LOG_FILE
        exit 1
    fi
    echo "✅ Aider 安装成功" | tee -a $LOG_FILE
else
    echo "✅ Aider 已安装" | tee -a $LOG_FILE
fi

# 3. 启动 Fetch App (如果未运行)
if ! pgrep -f "Fetch.app/Contents/MacOS/Fetch" > /dev/null; then
    echo "🚀 启动 Fetch App..." | tee -a $LOG_FILE
    open -n -g ./Fetch.app 2>&1 | tee -a $LOG_FILE
    echo "⏳ 等待服务器启动 (7秒)..." | tee -a $LOG_FILE
    sleep 7
else
    echo "ℹ️ Fetch App 已在运行" | tee -a $LOG_FILE
fi

# 3.5. 验证 API 服务是否可用
echo "   [2/4] 验证 API 服务..." | tee -a $LOG_FILE
API_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/v1/models 2>/dev/null)
if [ "$API_RESPONSE" != "200" ]; then
    echo "❌ API 服务未响应 (状态码: $API_RESPONSE)" | tee -a $LOG_FILE
    echo "   请确保 Fetch App 正在运行且已登录 Gemini" | tee -a $LOG_FILE
    exit 1
fi
echo "✅ API 服务正常 (HTTP $API_RESPONSE)" | tee -a $LOG_FILE

# 3.6. 测试 Gemini 连接（发送一个简单请求）
echo "   测试 Gemini 连接..." | tee -a $LOG_FILE
TEST_RESPONSE=$(curl -s http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test" \
  -d '{"model":"gemini-2.0-flash","messages":[{"role":"user","content":"say hello"}]}' 2>/dev/null)

if echo "$TEST_RESPONSE" | grep -q "Gemini error\|not ready\|not logged in"; then
    echo "❌ Gemini 未登录或未就绪" | tee -a $LOG_FILE
    echo "   请打开 Fetch App 并登录 Gemini" | tee -a $LOG_FILE
    echo "   响应: $TEST_RESPONSE" | tee -a $LOG_FILE
    exit 1
fi
echo "✅ Gemini 连接正常" | tee -a $LOG_FILE

# 4. 执行 Aider 指令 (核心测试)
# 这里的 --message 是发给 Gemini 的 prompt
# --no-git 防止自动提交 git
# --yes 自动确认所有操作
# 我们要求把文件内容修改为特定的暗号 "LINK_ESTABLISHED"
echo "   [3/4] 发送指令给 Aider (经由 Port 3000)..." | tee -a $LOG_FILE
echo "   指令: 将 $TEST_FILE 内容改为 'LINK_ESTABLISHED'" | tee -a $LOG_FILE
echo "   (这需要 Aider -> Fetch -> Gemini -> Aider -> 文件系统 的完整链路)" | tee -a $LOG_FILE

# 记录修改前的内容
BEFORE_CONTENT=$(cat $TEST_FILE)
echo "   修改前内容: $BEFORE_CONTENT" | tee -a $LOG_FILE

# 执行 Aider 命令
# macOS 没有 timeout 命令，使用后台进程 + sleep 实现超时
echo "   开始执行 Aider 命令..." | tee -a $LOG_FILE

aider \
  --model $AIDER_MODEL \
  --no-git \
  --yes \
  --message "Please overwrite the content of $TEST_FILE with exactly one word: LINK_ESTABLISHED" \
  $TEST_FILE >> $LOG_FILE 2>&1 &

AIDER_PID=$!
echo "   Aider PID: $AIDER_PID" | tee -a $LOG_FILE

# 等待最多 60 秒
for i in {1..60}; do
    if ! ps -p $AIDER_PID > /dev/null 2>&1; then
        # 进程已结束
        wait $AIDER_PID
        AIDER_EXIT_CODE=$?
        break
    fi
    sleep 1
    if [ $i -eq 60 ]; then
        echo "❌ Aider 操作超时（60秒），终止进程" | tee -a $LOG_FILE
        kill $AIDER_PID 2>/dev/null
        AIDER_EXIT_CODE=124
        break
    fi
done

if [ $AIDER_EXIT_CODE -eq 124 ]; then
    echo "❌ Aider 操作超时（60秒）" | tee -a $LOG_FILE
    exit 1
elif [ $AIDER_EXIT_CODE -ne 0 ]; then
    echo "⚠️ Aider 退出码: $AIDER_EXIT_CODE" | tee -a $LOG_FILE
    echo "   查看日志了解详情..." | tee -a $LOG_FILE
fi

# 5. 验收结果
echo "   [4/4] 验证结果..." | tee -a $LOG_FILE
CURRENT_CONTENT=$(cat $TEST_FILE 2>/dev/null || echo "")

echo "   修改后内容: $CURRENT_CONTENT" | tee -a $LOG_FILE

if [[ "$CURRENT_CONTENT" == *"LINK_ESTABLISHED"* ]]; then
    echo "" | tee -a $LOG_FILE
    echo "==============================" | tee -a $LOG_FILE
    echo "✅✅✅ 测试通过！(SUCCESS)" | tee -a $LOG_FILE
    echo "   Aider 成功接收指令 -> Fetch 转发 -> Gemini 生成 -> Aider 写入本地" | tee -a $LOG_FILE
    echo "   神经链路已贯通！" | tee -a $LOG_FILE
    echo "==============================" | tee -a $LOG_FILE
    exit 0
else
    echo "" | tee -a $LOG_FILE
    echo "==============================" | tee -a $LOG_FILE
    echo "❌❌❌ 测试失败！(FAILURE)" | tee -a $LOG_FILE
    echo "   期望内容包含: LINK_ESTABLISHED" | tee -a $LOG_FILE
    echo "   实际内容: $CURRENT_CONTENT" | tee -a $LOG_FILE
    echo "   请检查日志 $LOG_FILE 查看 Aider 报错信息" | tee -a $LOG_FILE
    echo "==============================" | tee -a $LOG_FILE
    exit 1
fi

