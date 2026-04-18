import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAuth

@main
struct talkoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authManager: AuthManager
    @StateObject private var subscriptionManager: SubscriptionManager
    @State private var selectedMode: ConversationMode? = nil
    @State private var selectedTab: MainTab = .text
    @State private var textInputIsEmpty: Bool = true
    @State private var textHasTranslation: Bool = false
    @State private var textASRActive: Bool = false
    @State private var textKeyboardVisible: Bool = false

    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithTransparentBackground()
        tabBarAppearance.backgroundEffect = nil
        tabBarAppearance.backgroundColor = UIColor(AppTheme.pageBackground).withAlphaComponent(0.35)
        tabBarAppearance.shadowColor = .clear
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        UITabBar.appearance().isTranslucent = true

        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.backgroundEffect = nil
        navBarAppearance.backgroundColor = .clear
        navBarAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance

        _authManager = StateObject(wrappedValue: AuthManager.shared)
        _subscriptionManager = StateObject(wrappedValue: SubscriptionManager.shared)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    ZStack(alignment: .bottom) {
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

                        if selectedTab == .text && !textKeyboardVisible && !(textHasTranslation && !textInputIsEmpty) {
                            CircleMicToggleButton(
                                isActive: textASRActive,
                                onToggle: {
                                    if textASRActive {
                                        NotificationCenter.default.post(name: .textTranslateMicHoldStop, object: nil)
                                    } else {
                                        NotificationCenter.default.post(name: .textTranslateMicHoldStart, object: nil)
                                    }
                                }
                            )
                            .padding(.bottom, 64)
                        }
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
            .onReceive(NotificationCenter.default.publisher(for: .textTranslateInputStateChanged)) { note in
                if let payload = note.object as? (Bool, Bool, Bool) {
                    textInputIsEmpty = payload.0
                    textHasTranslation = payload.1
                    textASRActive = payload.2
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                textKeyboardVisible = true
                if textASRActive {
                    NotificationCenter.default.post(name: .textTranslateMicHoldStop, object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                textKeyboardVisible = false
            }
        }
    }
}

enum MainTab {
    case text
    case conversation
}

private struct CircleMicToggleButton: View {
    let isActive: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isActive ? "mic.fill" : "mic")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .background(Circle().fill(isActive ? Color.red : AppTheme.googleBlue))
                .shadow(color: (isActive ? Color.red : AppTheme.googleBlue).opacity(isActive ? 0.32 : 0.14), radius: isActive ? 12 : 7, x: 0, y: 4)
                .scaleEffect(isActive ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isActive)
        }
        .buttonStyle(.plain)
    }
}
