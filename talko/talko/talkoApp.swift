import SwiftUI
import FirebaseCore
import FirebaseAuth

@main
struct talkoApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var selectedMode: ConversationMode? = nil

    init() {
        // Firebase 初始化：必须在使用 FirebaseAuth/GoogleSignIn 前完成
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    if let mode = selectedMode {
                        ContentView(mode: mode) {
                            selectedMode = nil
                        }
                    } else {
                        ModeSelectionView(selectedMode: $selectedMode)
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
