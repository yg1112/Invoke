#!/bin/bash

# Fetch App 启动脚本
# 使用方法: ./start_fetch.sh

echo "🚀 启动 Fetch App..."
echo ""

# 检查是否已经在运行
if lsof -i :3000 > /dev/null 2>&1; then
    echo "✅ Fetch App 已经在运行 (端口 3000)"
    echo ""
    echo "📱 如果看不到窗口，请："
    echo "   1. 检查 Dock 栏是否有 Fetch 图标"
    echo "   2. 在 Spotlight 搜索 'Invoke'"
    echo "   3. 或运行: open -a Invoke"
    echo ""
    exit 0
fi

# 编译（如果需要）
if [ ! -f ".build/debug/Invoke" ]; then
    echo "📦 编译项目..."
    swift build
fi

# 启动 App
echo "🎬 启动 App..."
cd "$(dirname "$0")"
.build/debug/Invoke > /tmp/fetch.log 2>&1 &
APP_PID=$!

echo "✅ Fetch App 已启动 (PID: $APP_PID)"
echo "📝 日志文件: /tmp/fetch.log"
echo ""
echo "⏳ 等待 3 秒让 App 初始化..."
sleep 3

# 检查端口
if lsof -i :3000 > /dev/null 2>&1; then
    echo "✅ API 服务器已启动 (端口 3000)"
else
    echo "⚠️  API 服务器未启动，请检查日志"
    echo "   查看日志: tail -f /tmp/fetch.log"
fi

echo ""
echo "📱 下一步："
echo "   1. 查找 Fetch App 窗口（可能在后台）"
echo "   2. 点击 'Login' 按钮完成登录"
echo "   3. 运行测试: ./test_api_server.sh"
echo ""



