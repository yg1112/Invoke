#!/usr/bin/env python3
"""
Invoke Bulk Code Export Parser
从剪贴板读取 Gemini 的 "Copy Response" 内容，自动切分并写入文件。

使用方法:
1. 在 Gemini 中让它生成代码 (包含 @code 触发词)
2. 点击 Gemini 回复框右上角的 "Copy Response" 按钮
3. 运行: python3 apply.py

如果自动读取剪贴板失败，可以手动粘贴内容然后按 Ctrl+D 结束。
"""

import sys
import os
import re

# 尝试导入 pyperclip 以自动读取剪贴板
# 如果没有安装，请运行: pip install pyperclip
try:
    import pyperclip
    HAS_CLIPBOARD = True
except ImportError:
    HAS_CLIPBOARD = False


def save_files_from_response(text):
    """从 Gemini 回复中解析文件并写入磁盘"""
    
    # 正则表达式匹配多种标记格式:
    # 1. <<<FILE>>> path ... <<<END>>> (新格式，不会被 Markdown 转义)
    # 2. __FILE_START__ path ... __FILE_END__ (原始格式)
    # 3. **FILE_START** path ... **FILE_END** (Gemini Markdown 转义后)
    # re.DOTALL 让 . 可以匹配换行符
    pattern = re.compile(
        r'(?:<<<FILE>>>|__FILE_START__|\*\*FILE_START\*\*)\s+(.*?)\n(.*?)(?:<<<END>>>|__FILE_END__|\*\*FILE_END\*\*)',
        re.DOTALL
    )
    
    matches = pattern.findall(text)
    
    if not matches:
        print("⚠️  未检测到文件标记。")
        print("请确认 Gemini 回复中包含以下标记之一:")
        print("  - <<<FILE>>> ... <<<END>>>")
        print("  - __FILE_START__ ... __FILE_END__")
        print("  - **FILE_START** ... **FILE_END**")
        print("\n📋 剪贴板内容预览:")
        print(text[:500] if len(text) > 500 else text)
        return False

    print(f"📦 检测到 {len(matches)} 个文件，准备写入...")
    print("=" * 50)

    success_count = 0
    for file_path, content in matches:
        # 清理路径和内容的前后空白
        file_path = file_path.strip()
        
        # 移除可能存在的 markdown 代码块标记 (```swift ... ```) 以防万一 Gemini 加了
        clean_content = re.sub(r'^```\w*\n', '', content.strip())
        clean_content = re.sub(r'\n```$', '', clean_content)
        
        # 确保目录存在
        full_path = os.path.abspath(file_path)
        dir_name = os.path.dirname(full_path)
        
        if not os.path.exists(dir_name):
            os.makedirs(dir_name)
            print(f"   📁 创建目录: {dir_name}")
        
        # 写入文件 (全量覆盖)
        try:
            with open(full_path, 'w', encoding='utf-8') as f:
                f.write(clean_content + '\n')  # 补一个换行符
            print(f"   ✅ 已写入: {file_path} ({len(clean_content)} 字符)")
            success_count += 1
        except Exception as e:
            print(f"   ❌ 写入失败 {file_path}: {e}")
    
    print("=" * 50)
    print(f"🎉 完成！成功写入 {success_count}/{len(matches)} 个文件")
    return success_count > 0


def main():
    print("🚀 Invoke Bulk Code Export Parser")
    print("-" * 40)
    
    content = ""
    
    if HAS_CLIPBOARD:
        print("📋 正在读取剪贴板内容...")
        try:
            content = pyperclip.paste()
        except Exception as e:
            print(f"⚠️  读取剪贴板失败: {e}")
            content = ""
    else:
        print("💡 提示: 安装 pyperclip 可自动读取剪贴板")
        print("   pip install pyperclip")
    
    # 如果剪贴板没东西，或者没装库，允许手动粘贴
    if not content or len(content) < 10:
        if HAS_CLIPBOARD:
            print("📋 剪贴板为空，请手动粘贴 Gemini 回复，按 Ctrl+D (Mac) 或 Ctrl+Z (Win) 结束:")
        else:
            print("📋 请手动粘贴 Gemini 回复，按 Ctrl+D (Mac) 或 Ctrl+Z (Win) 结束:")
        try:
            content = sys.stdin.read()
        except KeyboardInterrupt:
            print("\n🛑 操作取消")
            return
    
    if content:
        print(f"📝 收到 {len(content)} 字符的内容")
        save_files_from_response(content)
    else:
        print("⚠️  没有收到任何内容")


if __name__ == "__main__":
    main()
