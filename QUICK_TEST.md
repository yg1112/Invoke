# ⚡ Fetch 快速测试指南

## ✅ 当前状态

- ✅ **API 服务器运行中** - `http://127.0.0.1:3000`
- ✅ **模型列表正常** - `/v1/models` 返回正确
- ⚠️ **需要登录** - Chat Completions 需要 Gemini 登录

---

## 🎯 快速测试步骤

### 1. 找到 Fetch App 窗口

App 已经在运行，但窗口可能被隐藏。尝试以下方法：

**方法 A: 通过 Spotlight**
```bash
# 按 Cmd+Space，搜索 "Invoke"
```

**方法 B: 通过 Dock**
- 查看 Dock 栏是否有小鸟图标 🐦
- 点击图标激活窗口

**方法 C: 强制激活（终端）**
```bash
cd /Users/yukungao/github/Fetch
osascript -e 'tell application "System Events" to set frontmost of first process whose name contains "Invoke" to true'
```

### 2. 完成登录

在 Fetch App 窗口中：
1. 点击 **"Login"** 按钮
2. 在弹出窗口中完成 Google 登录
3. 等待 "叮" 声，窗口自动关闭
4. 状态变为 **"🟢 Connected"**

### 3. 运行测试

```bash
cd /Users/yukungao/github/Fetch
./test_api_server.sh
```

如果看到 "✅ Chat Completions 成功！"，说明一切正常！

---

## 🧪 手动测试命令

### 测试 Chat Completions

```bash
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.0-flash",
    "messages": [{"role": "user", "content": "Say hello"}]
  }' | python3 -m json.tool
```

**成功响应示例：**
```json
{
  "id": "chatcmpl-...",
  "choices": [{
    "message": {
      "content": "Hello!",
      "role": "assistant"
    }
  }]
}
```

### 测试 Aider 连接

```bash
# 创建测试目录
mkdir -p ~/Desktop/test_repo
cd ~/Desktop/test_repo

# 运行 Aider
aider \
  --openai-api-base http://127.0.0.1:3000/v1 \
  --openai-api-key fetch-key \
  --model openai/gemini-2.0-flash \
  --no-git \
  --message "Write a hello world python script"
```

---

## 📊 当前测试结果

运行 `./test_api_server.sh` 的输出：

```
✅ 端口 3000 正在监听
✅ API 服务器响应正常
✅ 模型列表获取成功
⚠️  Gemini 未登录（需要完成登录）
✅ Aider 已安装
```

---

## 🐛 如果窗口找不到

1. **检查进程**
   ```bash
   ps aux | grep Invoke | grep -v grep
   ```

2. **查看日志**
   ```bash
   tail -f /tmp/fetch.log
   ```

3. **重启 App**
   ```bash
   # 停止当前进程
   killall Invoke 2>/dev/null
   
   # 重新启动
   cd /Users/yukungao/github/Fetch
   ./start_fetch.sh
   ```

---

## ✨ 下一步

登录完成后，你可以：

1. ✅ 使用 `curl` 测试 API
2. ✅ 使用 Aider 进行代码编辑
3. ✅ 集成到其他工具中

**享受你的本地 AI 编程助手！** 🎉



