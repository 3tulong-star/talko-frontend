import SwiftUI
import Foundation

struct ModeSelectionView: View {
    @Binding var selectedMode: ConversationMode?
    @StateObject private var authManager = AuthManager.shared
    @State private var usageText: String = "剩余时长加载中..."
    @State private var usageTextColor: Color = .secondary
    // nil = usage 未读取成功，先允许进入模式，避免页面“点了没反应”
    @State private var remainingSeconds: Int? = nil

    private let httpBase = URL(string: "https://tulong.zeabur.app")!

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            
            VStack(spacing: 30) {
                HStack {
                    Spacer()
                    Button {
                        authManager.signOut()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("退出登录")
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                VStack(spacing: 8) {
                    Text("Seam Translate")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("选择适合您的翻译模式")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(usageText)
                        .font(.footnote)
                        .foregroundColor(usageTextColor)
                        .padding(.top, 4)
                }
                .padding(.top, 20)

                ScrollView {
                    VStack(spacing: 20) {
                        ModeCard(
                            title: "双按钮模式",
                            description: "人工控制左右说话时机，适合精准对话",
                            icon: "person.2.fill",
                            color: .blue
                        ) {
                            guard canEnterMode else { return }
                            selectedMode = .dualButton
                        }

                        ModeCard(
                            title: "单按钮模式",
                            description: "轮流按下说话，自动识别语种分配左右",
                            icon: "mic.circle.fill",
                            color: .green
                        ) {
                            guard canEnterMode else { return }
                            selectedMode = .singleButton
                        }

                        ModeCard(
                            title: "Live 模式",
                            description: "自由对话，持续识别分句，无须手动按键",
                            icon: "bolt.horizontal.circle.fill",
                            color: .orange
                        ) {
                            guard canEnterMode else { return }
                            selectedMode = .live
                        }
                    }
                    .padding(20)
                }

                Spacer()
            }
        }
        .task {
            await refreshUsage()
        }
    }

    private func refreshUsage() async {
        guard let token = await AuthManager.shared.getIDToken() else {
            usageText = "未登录，无法获取时长"
            usageTextColor = .red
            remainingSeconds = nil
            return
        }

        var req = URLRequest(url: httpBase.appendingPathComponent("/api/v1/usage/me"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                usageText = "时长读取失败：无响应状态"
                usageTextColor = .red
                remainingSeconds = nil
                print("[Usage] invalid response object")
                return
            }

            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                usageText = "时长读取失败（HTTP \(http.statusCode)）"
                usageTextColor = .red
                remainingSeconds = nil
                print("[Usage] HTTP \(http.statusCode), body=\(body)")
                return
            }

            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            let remaining = max(0, decoded.remainingSeconds)
            remainingSeconds = remaining

            let remainMin = Int(ceil(Double(remaining) / 60.0))
            let usedMin = Int(decoded.usageSecondsTotal / 60)
            let limitMin = Int(decoded.usageLimitSeconds / 60)

            usageText = "已用 \(usedMin) 分钟 / 共 \(limitMin) 分钟，剩余约 \(remainMin) 分钟"
            usageTextColor = remaining > 0 ? .secondary : .red
            print("[Usage] success: used=\(decoded.usageSecondsTotal), limit=\(decoded.usageLimitSeconds), remain=\(decoded.remainingSeconds)")
        } catch {
            usageText = "时长读取失败（解析/网络）"
            usageTextColor = .red
            remainingSeconds = nil
            print("[Usage] request/decode error: \(error)")
        }
    }

    private var canEnterMode: Bool {
        // 读取失败时先不阻塞入口，真正限流由后端 WS 拦截。
        guard let remainingSeconds else { return true }
        return remainingSeconds > 0
    }
}

private struct UsageResponse: Decodable {
    let uid: String
    let usageSecondsTotal: Int
    let usageLimitSeconds: Int
    let remainingSeconds: Int
}

struct ModeCard: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(color)
                    .cornerRadius(15)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(20)
            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
