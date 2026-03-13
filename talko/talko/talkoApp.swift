import SwiftUI
import FirebaseCore
import FirebaseAuth

@main
struct talkoApp: App {
    @StateObject private var authManager: AuthManager
    @StateObject private var subscriptionManager: SubscriptionManager
    @State private var selectedMode: ConversationMode? = nil
    @State private var selectedTab: MainTab = .text

    init() {
        // Firebase 初始化：必须在使用 FirebaseAuth/GoogleSignIn 前完成
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        _authManager = StateObject(wrappedValue: AuthManager.shared)
        _subscriptionManager = StateObject(wrappedValue: SubscriptionManager.shared)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    TabView(selection: $selectedTab) {
                        TextTranslateView()
                            .tabItem {
                                Label("文本翻译", systemImage: "text.bubble")
                            }
                            .tag(MainTab.text)

                        NavigationStack {
                            ModeSelectionView(selectedMode: $selectedMode)
                        }
                        .tabItem {
                            Label("对话翻译", systemImage: "waveform")
                        }
                        .tag(MainTab.conversation)
                    }
                    .fullScreenCover(
                        isPresented: Binding(
                            get: { selectedMode != nil },
                            set: { if !$0 { selectedMode = nil } }
                        )
                    ) {
                        if let mode = selectedMode {
                            ContentView(mode: mode) {
                                selectedMode = nil
                            }
                        }
                    }
                } else {
                    LoginView()
                }
            }
            .onAppear {
                if let uid = authManager.user?.uid {
                    subscriptionManager.syncUser(uid: uid)
                }
            }
            .onChange(of: authManager.user) {
                if let uid = authManager.user?.uid {
                    subscriptionManager.syncUser(uid: uid)
                }
            }
        }
    }
}

enum MainTab {
    case text
    case conversation
}
