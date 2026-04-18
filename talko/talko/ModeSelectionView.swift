import SwiftUI
import Foundation

struct ModeSelectionView: View {
    @Binding var selectedMode: ConversationMode?
    @StateObject private var authManager = AuthManager.shared
    @State private var usageText: String = NSLocalizedString("usage_loading", comment: "")
    @State private var usageTextColor: Color = .secondary
    @State private var showingProfile = false
    // nil = usage 未读取成功，先允许进入模式，避免页面“点了没反应”
    @State private var remainingSeconds: Int? = nil

    private let httpBase = AppConfig.httpBaseURL

    var body: some View {
        NavigationStack {
            ZStack {
                AppTechBackground()
                    .ignoresSafeArea()

                VStack(spacing: 22) {
                    headerBar
                    heroSection

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            ModeCard(
                                title: NSLocalizedString("mode_dual_title", comment: ""),
                                description: NSLocalizedString("mode_dual_desc", comment: ""),
                                icon: "person.2.fill",
                                accent: AppTheme.googleBlue,
                                isLive: false
                            ) {
                                guard canEnterMode else { return }
                                selectedMode = .dualButton
                            }

                            ModeCard(
                                title: NSLocalizedString("mode_single_title", comment: ""),
                                description: NSLocalizedString("mode_single_desc", comment: ""),
                                icon: "mic.circle.fill",
                                accent: AppTheme.googleBlueDark,
                                isLive: false
                            ) {
                                guard canEnterMode else { return }
                                selectedMode = .singleButton
                            }

                            ModeCard(
                                title: NSLocalizedString("mode_live_title", comment: ""),
                                description: NSLocalizedString("mode_live_desc", comment: ""),
                                icon: "bolt.horizontal.circle.fill",
                                accent: Color.blue,
                                isLive: true
                            ) {
                                guard canEnterMode else { return }
                                selectedMode = .live
                            }

#if DEBUG
                            NavigationLink {
                                LiveProviderTestView()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "flask.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(AppTheme.googleBlue)
                                        .frame(width: 38, height: 38)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(AppTheme.subtleBlue)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Live Provider Test")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                        Text("Debug ASR / Translate / TTS routing")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.blue.opacity(0.7))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(.white.opacity(0.85))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(AppTheme.cardBorder, lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
#endif
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.top, 8)
            }
        }
        .task {
            await refreshUsage()
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView(onSignedOut: {
                showingProfile = false
            })
        }
    }

    private var headerBar: some View {
        HStack {
            Spacer()
            Button {
                showingProfile = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle")
                    Text(NSLocalizedString("profile", comment: ""))
                }
                .font(.caption.weight(.medium))
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .overlay(
                            Capsule().stroke(Color.blue.opacity(0.18), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }

    private var heroSection: some View {
        VStack(spacing: 8) {
            Text("Talko")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.blue.opacity(0.95), .blue.opacity(0.65)], startPoint: .leading, endPoint: .trailing)
                )

            Text(NSLocalizedString("mode_subtitle", comment: ""))
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(usageText)
                .font(.footnote)
                .foregroundColor(usageTextColor)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
    }

    private func refreshUsage() async {
        if AuthManager.shared.isGuestMode {
            usageText = NSLocalizedString("usage_guest", comment: "")
            usageTextColor = .orange
            remainingSeconds = nil
            return
        }

        guard let token = await AuthManager.shared.getIDToken() else {
            usageText = NSLocalizedString("usage_not_logged_in", comment: "")
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
                usageText = NSLocalizedString("usage_failed_no_response", comment: "")
                usageTextColor = .red
                remainingSeconds = nil
                print("[Usage] invalid response object")
                return
            }

            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                usageText = String(format: NSLocalizedString("usage_failed_http", comment: ""), http.statusCode)
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

            usageText = String(format: NSLocalizedString("usage_summary", comment: ""), usedMin, limitMin, remainMin)
            usageTextColor = remaining > 0 ? .secondary : .red
            print("[Usage] success: used=\(decoded.usageSecondsTotal), limit=\(decoded.usageLimitSeconds), remain=\(decoded.remainingSeconds)")
        } catch {
            usageText = NSLocalizedString("usage_failed_network", comment: "")
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

private struct AppTechBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.pageBackground, Color.white],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(AppTheme.googleBlue.opacity(0.10))
                .frame(width: 280, height: 280)
                .blur(radius: 36)
                .offset(x: -130, y: -290)

            Circle()
                .fill(AppTheme.googleBlue.opacity(0.07))
                .frame(width: 220, height: 220)
                .blur(radius: 30)
                .offset(x: 140, y: -180)
        }
    }
}

struct ModeCard: View {
    let title: String
    let description: String
    let icon: String
    let accent: Color
    let isLive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)

                    if isLive {
                        LiveWaveformGlyph()
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        if isLive {
                            Text("LIVE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.12)))
                        }
                    }

                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(accent.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: accent.opacity(0.08), radius: 12, x: 0, y: 6)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct LiveWaveformGlyph: View {
    private let baseHeights: [CGFloat] = [8, 11, 15, 11, 8]
    private let phases: [Double] = [0.0, 0.9, 1.8, 2.7, 3.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2.6) {
                ForEach(0..<5, id: \.self) { idx in
                    let amp = 0.72 + 0.28 * abs(sin((t * 2.35) + phases[idx]))
                    RoundedRectangle(cornerRadius: 1.4)
                        .fill(Color.white.opacity(0.96))
                        .frame(width: 3.0, height: max(6, baseHeights[idx] * amp))
                }
            }
            .frame(width: 26, height: 16, alignment: .center)
        }
    }
}
