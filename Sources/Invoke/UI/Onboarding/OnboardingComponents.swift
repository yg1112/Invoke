import SwiftUI

// MARK: - 工作流动画视图
struct WorkflowAnimationView: View {
    @State private var phase: Int = 0
    @State private var showFlow: Bool = false
    
    var body: some View {
        HStack(spacing: 40) {
            // Gemini 窗口
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 120, height: 160)
                    .overlay(
                        VStack {
                            Image(systemName: "sparkles")
                                .font(.system(size: 30))
                                .foregroundColor(.purple)
                            Text("Gemini")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if phase >= 1 {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.caption)
                                    Text("Copy")
                                        .font(.caption)
                                }
                                .padding(6)
                                .background(Color.purple.opacity(0.2))
                                .cornerRadius(6)
                                .transition(.scale)
                            }
                        }
                        .padding()
                    )
                
                Text("Ask question →\nGet Base64 code")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // 电流动画
            if showFlow {
                FlowAnimationView()
                    .frame(width: 60, height: 4)
                    .transition(.opacity)
            } else {
                Spacer().frame(width: 60, height: 4)
            }
            
            // Invoke App
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 160)
                    .overlay(
                        VStack {
                            Image(systemName: "cpu")
                                .font(.system(size: 30))
                                .foregroundColor(.blue)
                            Text("Invoke")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if phase >= 2 {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.title2)
                                    .transition(.scale)
                            }
                        }
                        .padding()
                    )
                
                Text("Auto-detect\n& Process")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // 电流动画
            if phase >= 2 {
                FlowAnimationView()
                    .frame(width: 60, height: 4)
                    .transition(.opacity)
            } else {
                Spacer().frame(width: 60, height: 4)
            }
            
            // Code Editor
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 120, height: 160)
                    .overlay(
                        VStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 30))
                                .foregroundColor(.green)
                            Text("Code")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if phase >= 3 {
                                Spacer()
                                VStack(spacing: 4) {
                                    Text("Files updated!")
                                        .font(.system(size: 9))
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundColor(.green)
                                }
                                .transition(.scale)
                            }
                        }
                        .padding()
                    )
                
                Text("Files updated\n& Git commit")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            startAnimation()
        }
    }
    
    func startAnimation() {
        // Phase 0 → 1: Gemini 生成代码
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring()) {
                phase = 1
            }
        }
        
        // Phase 1 → 2: 点击复制，电流流动
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.5)) {
                showFlow = true
            }
            withAnimation(.spring().delay(0.5)) {
                phase = 2
            }
        }
        
        // Phase 2 → 3: Invoke 处理完成，传递到编辑器
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation(.spring()) {
                phase = 3
            }
        }
        
        // 循环动画
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            phase = 0
            showFlow = false
            startAnimation()
        }
    }
}

// 电流流动动画
struct FlowAnimationView: View {
    @State private var offset: CGFloat = -100
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景线
                Rectangle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(height: 2)
                
                // 流动的光点
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .blue, .cyan, .blue, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 40, height: 4)
                    .offset(x: offset)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                offset = 100
            }
        }
    }
}

// MARK: - INVISIBLE BRIDGE: ModeOptionCard removed - Aider handles all Git logic

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 24)
                .foregroundColor(isGranted ? .green : .primary)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .fontWeight(.semibold)
                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InstructionRow: View {
    let number: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .clipShape(Circle())
            
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

// INVISIBLE BRIDGE: GitMode extension removed - Aider handles all Git operations
