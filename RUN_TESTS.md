# 🚀 快速测试指南 (Quick Test Guide)

## 完整测试计划

完整的测试文档请查看：[IRON_TEST_PLAN.md](IRON_TEST_PLAN.md)

---

## 快速执行步骤

### 第一步：启动 Fetch App

```bash
# 编译
swift build

# 启动（会打开 GUI 窗口）
.build/debug/Invoke
```

**等待以下状态**：
- ✅ Shadow Window 显示 Gemini 页面
- ✅ 右上角显示 "🟢 Connected"（绿色状态）
- ✅ 底部显示 "✅ API Server on port 3000"

---

### 第二步：执行第一关测试（基建验收）

**在新的终端窗口运行**：
```bash
./test_iron_round1_manual.sh
```

**预期输出**：
```
[0 s](+0s) 1
[1 s](+1s) 2
[2 s](+1s) 3
...
[8 s](+1s) 10
✅ 第一关：PASS
```

**如果看到**：
```
[3 s](+0s) 12345678910
❌ 第一关：FAIL（假流式）
```

说明流式传输失败，请查看 [IRON_TEST_PLAN.md](IRON_TEST_PLAN.md) 的故障排查指南。

---

### 第三步：执行第二关测试（手脑协调）

#### 3.1 准备测试环境

```bash
mkdir -p ~/test_aider_workspace
```

#### 3.2 在 Fetch App 中操作

1. 点击 "Select Project Root"
2. 选择 `~/test_aider_workspace`
3. 等待 Aider 启动（底部显示 "Aider ready"）

#### 3.3 发送测试指令

在 Fetch 输入框输入：
```
创建一个 greetings.py，里面写一个函数 say_hello(name)，打印 'Hello, {name}'。不要废话，直接写代码。
```

#### 3.4 验证结果

```bash
# 检查文件是否生成
cat ~/test_aider_workspace/greetings.py
```

**期望输出**：
```python
def say_hello(name):
    print(f'Hello, {name}')
```

✅ **PASS**：文件存在且内容正确
❌ **FAIL**：文件不存在或 Aider 报错

---

### 第四步：执行第三关测试（多回合记忆）

#### 4.1 第一次修改

在 Fetch 输入框输入：
```
把刚才那个函数里的 'Hello' 改成 'Greetings'。
```

**验证**：
```bash
cat ~/test_aider_workspace/greetings.py
# 应该看到 'Greetings' 而非 'Hello'
```

#### 4.2 第二次修改

在 Fetch 输入框输入：
```
再给它加一个 docstring 注释。
```

**验证**：
```bash
cat ~/test_aider_workspace/greetings.py
# 应该看到函数有 docstring
```

✅ **PASS**：两次修改都正确，Gemini 记得上下文
❌ **FAIL**：Gemini 问 "哪个文件？" 或修改错误的内容

---

### 第五步：执行终极关卡（自愈闭环）

#### 5.1 清空环境

```bash
cd ~/test_aider_workspace
rm -f *.swift *.py
```

#### 5.2 发送自愈测试指令

在 Fetch 输入框输入：
```
写一个 swift 文件 Calculator.swift，实现加法函数 add(a: Int, b: Int) -> Int。
然后写一个 main.swift 调用它。

请注意，在 main.swift 里故意把函数名写错（写成 addNumbers 但定义是 add），然后尝试运行 swift main.swift。

如果报错，请自动修复它并再次运行，直到成功。
```

#### 5.3 观察过程

**预期看到的消息流**：
1. "Created Calculator.swift and main.swift"
2. "Running swift main.swift..."
3. "Error: no member 'addNumbers'"
4. "I'll fix the function name..."
5. "Running again..."
6. "Success!"

✅ **PASS**：全程自动完成，无需人工干预
❌ **FAIL**：报错后停止，等待人类输入

---

## 测试结果报告

完成所有测试后，填写此表：

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ 关卡                    ┃ 状态   ┃ 备注                   ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━╋━━━━━━━━╋━━━━━━━━━━━━━━━━━━━━━━━━┫
┃ 🟥 第一关：基建验收     ┃ ⬜ PASS┃ 流式耗时：__s          ┃
┃                         ┃ ⬜ FAIL┃ 数据块数：__           ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━╋━━━━━━━━╋━━━━━━━━━━━━━━━━━━━━━━━━┫
┃ 🟨 第二关：手脑协调     ┃ ⬜ PASS┃ 文件生成：⬜ 是 ⬜ 否  ┃
┃                         ┃ ⬜ FAIL┃                        ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━╋━━━━━━━━╋━━━━━━━━━━━━━━━━━━━━━━━━┫
┃ 🟩 第三关：多回合记忆   ┃ ⬜ PASS┃ Context：⬜ 连贯 ⬜ 丢失┃
┃                         ┃ ⬜ FAIL┃                        ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━╋━━━━━━━━╋━━━━━━━━━━━━━━━━━━━━━━━━┫
┃ 👑 终极关卡：自愈闭环   ┃ ⬜ PASS┃ 自动修复：⬜ 是 ⬜ 否  ┃
┃                         ┃ ⬜ FAIL┃                        ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━┻━━━━━━━━┻━━━━━━━━━━━━━━━━━━━━━━━━┛
```

---

## 故障排查

如果任何测试失败，请查看详细的故障排查指南：
[IRON_TEST_PLAN.md - 故障排查指南](IRON_TEST_PLAN.md#🛠️-故障排查指南)

---

## 快速诊断命令

```bash
# 检查端口占用
lsof -i:3000

# 查看 App 日志
tail -f /tmp/fetch_app.log

# 检查 Aider 进程
ps aux | grep aider

# 测试 API 连通性
curl -s http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"test"}]}'
```
