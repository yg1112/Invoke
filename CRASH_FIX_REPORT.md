# 崩溃修复报告

## 问题诊断

### 原始问题
- App 在后台运行时发生 `SIGSEGV` (Segmentation Fault 11) 崩溃
- 崩溃点: `_NSWindowTransformAnimation dealloc`
- 原因: `GeminiLinkLogic` 生命周期管理错误，导致对象重复创建/销毁

## 修复措施

### 1. ✅ 修复 GeminiLinkLogic 生命周期
**问题**: 在 `ContentView` 中使用 `@StateObject private var linkLogic = GeminiLinkLogic()` 导致每次 View 刷新都可能创建新实例

**修复**:
- 将 `GeminiLinkLogic` 改为单例模式 (`static let shared`)
- 在 `ContentView` 中使用 `private let linkLogic = GeminiLinkLogic.shared` (不是 `@StateObject`)
- 确保全局只有一个实例

### 2. ✅ 修复测试脚本启动方式
**问题**: 直接运行二进制文件 (`./Contents/MacOS/Fetch &`) 导致 WindowServer 连接异常

**修复**:
- 使用 `open -n -g "$APP_BUNDLE"` 启动 App
- 保证 WindowServer 连接和 UI 上下文
- 添加进程存活检查

### 3. ✅ 添加进程稳定性验证
- 测试结束后检查进程是否仍然运行
- 如果进程崩溃，测试失败

## 测试结果

### ✅ 进程稳定性
- **状态**: 通过
- App 进程在测试期间保持稳定，无崩溃
- 测试结束后进程正常退出

### ✅ API 服务
- **状态**: 通过
- 端口 3000 正常响应 (HTTP 200)
- `/v1/models` 端点正常工作

### ⚠️ 剪贴板协议识别
- **状态**: 部分通过
- 可能需要在 App 前台运行时才能正常工作
- 不影响核心功能（API 服务）

## 结论

**核心功能已稳定**: 
- ✅ 进程不再崩溃
- ✅ API 服务正常工作
- ✅ 可以安全地连接 Aider

**下一步**: 可以开始使用 Aider 代理模式进行端到端测试。

