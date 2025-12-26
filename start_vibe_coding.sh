#!/bin/bash

# start_vibe_coding.sh - Vibe Coding 一键启动器
# 自动配置环境并启动 Aider 连接到 Fetch App

set -e

echo "🚀 Vibe Coding 启动器"
echo "=============================="

# 1. 检查 Fetch App 是否运行
echo ""
echo "[1/3] 检查 Fetch App..."
if ! pgrep -f "Fetch.app/Contents/MacOS/Fetch" > /dev/null; then
    echo "   ⚠️ Fetch App 未运行，正在启动..."
    if [ -f "./Fetch.app/Contents/MacOS/Fetch" ]; then
        open -n -g ./Fetch.app
        echo "   ⏳ 等待服务器启动 (5秒)..."
        sleep 5
    else
        echo "   ❌ 找不到 Fetch.app，请先启动 Fetch App"
        exit 1
    fi
else
    echo "   ✅ Fetch App 已在运行"
fi

# 2. 验证 API 服务
echo ""
echo "[2/3] 验证 API 服务..."
API_PORT=3000
MAX_RETRIES=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$API_PORT/v1/models" | grep -q "200"; then
        echo "   ✅ API 服务正常 (端口 $API_PORT)"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "   ⏳ 等待 API 服务启动... ($RETRY_COUNT/$MAX_RETRIES)"
            sleep 1
        else
            echo "   ❌ API 服务未响应，请确保 Fetch App 已登录 Gemini"
            exit 1
        fi
    fi
done

# 3. 配置环境变量
echo ""
echo "[3/3] 配置 Aider 环境..."
export OPENAI_API_BASE="http://127.0.0.1:$API_PORT/v1"
export OPENAI_API_KEY="local-fetch-key"

echo "   ✅ 环境变量已设置:"
echo "      OPENAI_API_BASE=$OPENAI_API_BASE"
echo "      OPENAI_API_KEY=$OPENAI_API_KEY"

# 4. 检查 Aider
if ! command -v aider &> /dev/null; then
    echo ""
    echo "   ⚠️ Aider 未找到，运行配置脚本..."
    if [ -f "./Setup_Aider_Path.sh" ]; then
        bash ./Setup_Aider_Path.sh
    else
        echo "   ❌ 找不到 Setup_Aider_Path.sh"
        echo "   💡 请手动安装: pip install aider-chat"
        exit 1
    fi
fi

# 5. 启动 Aider
echo ""
echo "=============================="
echo "✅ 环境就绪，启动 Aider..."
echo ""
echo "💡 使用提示:"
echo "   - Aider 已连接到 Fetch App"
echo "   - 所有请求将通过 Fetch 转发到 Gemini"
echo "   - 在 Aider 中正常使用即可"
echo ""
echo "🚀 启动 Aider (交互模式)..."
echo ""

# 获取当前项目路径（如果提供了参数）
PROJECT_PATH="${1:-$(pwd)}"
if [ ! -d "$PROJECT_PATH" ]; then
    PROJECT_PATH=$(pwd)
fi

# 启动 Aider
aider \
    --model openai/gemini-2.0-flash \
    --openai-api-base "$OPENAI_API_BASE" \
    --openai-api-key "$OPENAI_API_KEY" \
    --no-git \
    --no-show-model-warnings \
    "$PROJECT_PATH"

