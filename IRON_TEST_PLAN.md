# 🚀 铁律测试计划 (The Iron Test Plan)

## 目标
验证 Agent 不仅能"动"，还能"活"。扫除一切假流式、假记忆、假成功的盲点。

---

## 🟥 第一关：基建验收 (Infrastructure Verification)

### 目标
确认"管道"是通的，且流速正常。

### 盲点扫除
- ❌ **假流式**：Swift 攒一大坨再一次性吐出来
- ❌ **Zombie Server**：端口 3000 被旧进程占用

### 执行方式
```bash
./test_iron_plan_round1.sh
```

### ✅ 验收标准（PASS）
- **立即响应**：回车后 0.5秒内 必须看到终端开始跳字
- **逐行蹦字**：看到 `[0 s] 1` → `[2 s] 2` → `[4 s] 3`（时间戳递增）
- **正确结束**：收到 `[DONE]` 标记

### ❌ 失败判定（FAIL）
- 等了3秒，然后瞬间喷出 `[3 s] 12345678910`
- 超过 60 秒无响应

---

## 🟨 第二关：手脑协调验收 (Hand-Brain Coordination)

### 目标
确认 Aider (手) 能听懂 Gemini (脑) 的指挥，并物理修改文件。

### 盲点扫除
- ❌ **JSON 格式炸弹**：Gemini 输出特殊字符导致 Aider 解析失败
- ❌ **Markdown 干扰**：Gemini 用 ```json 包裹，Aider 需要纯文本
- ❌ **Swift 抢笔**：GeminiLinkLogic 抢在 Aider 前面写文件

### 执行步骤

#### 准备
1. 创建空测试文件夹：
   ```bash
   mkdir -p ~/test_aider_workspace
   cd ~/test_aider_workspace
   ```

2. 启动 Fetch App（GUI 模式）：
   ```bash
   .build/debug/Invoke
   ```

3. 在 Fetch 首页选择 `~/test_aider_workspace` 作为 Project Root

#### 测试指令
在 Fetch 的输入框输入：
```
创建一个 greetings.py，里面写一个函数 say_hello(name)，打印 'Hello, {name}'。不要废话，直接写代码。
```

### ✅ 验收标准（PASS）
1. **UI 响应**：Fetch 聊天界面显示 "Aider is thinking..."
2. **文件生成**：`~/test_aider_workspace/greetings.py` 凭空出现
3. **内容正确**：
   ```python
   def say_hello(name):
       print(f'Hello, {name}')
   ```
4. **归属验证**：检查 Fetch 日志，**不应该**出现 `GeminiLinkLogic` 字样

### ❌ 失败判定（FAIL）
- Aider 回复 "I am sorry, I cannot edit files"
- Fetch Log 里出现 `GeminiLinkLogic` 或 `MagicPaster` 字样
- 文件内容是 Markdown 格式而非纯 Python 代码

---

## 🟩 第三关：多回合记忆验收 (Multi-Turn Retention)

### 目标
确认 Gemini 网页版没有因为页面刷新或 ID 错乱而"失忆"。

### 盲点扫除
- ❌ **Context 漂移**：Aider 和 Gemini 的记忆叠加导致 Prompt 重复
- ❌ **Session 错乱**：每次请求进入不同的 Gemini 会话窗口

### 执行步骤（接第二关）

#### 测试指令 1
```
把刚才那个函数里的 'Hello' 改成 'Greetings'。
```

**期望结果**：
- `greetings.py` 被修改为：
  ```python
  def say_hello(name):
      print(f'Greetings, {name}')
  ```

#### 测试指令 2
```
再给它加一个 docstring 注释。
```

**期望结果**：
- `greetings.py` 再次被修改为：
  ```python
  def say_hello(name):
      """Greet a person by name."""
      print(f'Greetings, {name}')
  ```

### ✅ 验收标准（PASS）
1. **准确修改**：每次都正确修改了文件
2. **未发生幻觉**：Gemini 没有问 "哪个函数？" 或 "请提供代码"
3. **上下文连贯**：它知道我们在聊 `greetings.py`

### ❌ 失败判定（FAIL）
- Gemini 回复 "I don't see any code"（Context 没传进去）
- 开始写一个新的文件而非修改旧文件（失忆）

---

## 👑 终极关卡：自愈闭环 (The Self-Healing Loop)

### 目标
人为制造错误，看 Agent 能否自己发现并修正，全程无需人类干预。

### 盲点扫除
- ❌ **观察盲点**：Agent 执行了操作但看不到结果（如运行报错）
- ❌ **反思缺失**：Agent 看到错误但不知道如何修复
- ❌ **Main Thread 阻塞**：大量文本传输导致 App 卡死

### 执行步骤

#### 准备
```bash
cd ~/test_aider_workspace
rm -f *.swift  # 清空之前的文件
```

#### 测试指令
在 Fetch 输入框输入：
```
写一个 swift 文件 Calculator.swift，实现加法函数 add(a: Int, b: Int) -> Int。
然后写一个 main.swift 调用它。

请注意，在 main.swift 里故意把函数名写错（写成 addNumbers 但定义是 add），然后尝试运行 swift main.swift。

如果报错，请自动修复它并再次运行，直到成功。
```

### 预期剧本（The Script）

1. **Action 1**：Aider 创建 `Calculator.swift` (func add) 和 `main.swift` (调用 addNumbers)
2. **Action 2**：Aider 尝试运行 `swift main.swift`
3. **Observation**：终端报错 `error: value of type 'Calculator' has no member 'addNumbers'`
4. **Reflection (Brain)**：Gemini 收到报错（通过 Aider 传回）
5. **Correction (Hand)**：Gemini 输出 "I corrected the function name"，Aider 执行修改
6. **Success**：再次运行，成功

### ✅ 验收标准（PASS）
1. **一次指令完成**：你只需要发一次指令，全程无需人工干预
2. **完整链条**：Log 里出现 `Error → Fix → Success` 的完整链条
3. **死机测试**：Fetch App 没有因为大量文本传输而卡死（检查 Main Thread）

### ❌ 失败判定（FAIL）
- Agent 报错后停止，等待人类输入
- Agent 修复后没有自动重新运行验证
- App 在过程中崩溃或无响应

---

## 📊 总结报告模板

完成所有测试后，填写此表：

| 关卡 | 状态 | 备注 |
|------|------|------|
| 🟥 第一关：基建验收 | ⬜ PASS / ⬜ FAIL | 流式耗时：__s |
| 🟨 第二关：手脑协调 | ⬜ PASS / ⬜ FAIL | 文件生成：⬜ 是 / ⬜ 否 |
| 🟩 第三关：多回合记忆 | ⬜ PASS / ⬜ FAIL | Context 连贯：⬜ 是 / ⬜ 否 |
| 👑 终极关卡：自愈闭环 | ⬜ PASS / ⬜ FAIL | 自动修复：⬜ 是 / ⬜ 否 |

---

## 🛠️ 故障排查指南

### 第一关失败：假流式
**症状**：等3秒后一次性喷出所有内容

**排查**：
1. 检查 `LocalAPIServer.swift:142` - `streamAskGemini` 是否被调用
2. 检查 `GeminiWebManager.swift:179` - 100ms 轮询是否正常工作
3. 查看 `/tmp/fetch_app.log` 是否有 `📤 Streaming chunk` 日志

**修复方向**：
- 增加日志输出，确认 `onChunk` 回调是否被及时调用
- 检查 `connection.send` 是否有缓冲

---

### 第二关失败：文件未生成
**症状**：Aider 回复成功但文件不存在

**排查**：
1. 检查 `~/test_aider_workspace` 路径是否正确
2. 查看 Aider 日志（Fetch App 的 stdout）
3. 确认 Aider 进程是否真的在运行：`ps aux | grep aider`

**修复方向**：
- 检查 `AiderService.swift` 的 `--yes` 参数（自动确认文件操作）
- 验证 Aider 的工作目录是否设置正确

---

### 第三关失败：Context 丢失
**症状**：Gemini 问 "哪个文件？"

**排查**：
1. 检查 LocalAPIServer 是否正确传递 `messages` 数组
2. 查看 Gemini WebView 的聊天历史（打开 Shadow Window）
3. 确认每次请求的 `prompt` 是完整的还是增量的

**修复方向**：
- Aider 默认发送完整 `messages` 数组，确保 LocalAPIServer 没有截断
- 检查 Gemini WebView 是否被意外刷新（导致历史丢失）

---

### 终极关卡失败：不会自动修复
**症状**：报错后 Agent 停止，等待人类输入

**排查**：
1. 确认指令中是否明确要求"自动修复"
2. 查看 Gemini 的回复是否包含修复步骤
3. 检查 Aider 是否真的尝试运行命令（而非只是模拟）

**修复方向**：
- 在 Prompt 中更明确地要求："如果报错，立即修复并重试，不要等待确认"
- 检查 Aider 的 `--yes` 参数是否生效
