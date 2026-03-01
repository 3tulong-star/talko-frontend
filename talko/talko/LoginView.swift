import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            
            VStack(spacing: 40) {
                Spacer()
                
                // Logo & Title
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                        .symbolEffect(.bounce, value: authManager.isLoading)
                    
                    Text("Talko")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    
                    Text("实时语音翻译助手")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Login Buttons
                VStack(spacing: 16) {
                    // Apple Sign In
                    SignInWithAppleButton(.signIn) { request in
                        let nonce = authManager.startAppleSignIn()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = nonce
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                                Task {
                                    do {
                                        try await authManager.handleAppleSignIn(credential: appleIDCredential)
                                    } catch {
                                        self.errorMessage = error.localizedDescription
                                        self.showError = true
                                    }
                                }
                            }
                        case .failure(let error):
                            self.errorMessage = error.localizedDescription
                            self.showError = true
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 54)
                    .cornerRadius(27)
                    .padding(.horizontal, 40)
                    
                    // Google Sign In
                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack(spacing: 12) {
                            Image("google_logo") // 确保你工程里有这个图片，或者用系统图标代替
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                            
                            Text("使用 Google 登录")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white)
                        .cornerRadius(27)
                        .overlay(
                            RoundedRectangle(cornerRadius: 27)
                                .stroke(Color(UIColor.separator), lineWidth: 0.5)
                        )
                    }
                    .padding(.horizontal, 40)
                }
                .disabled(authManager.isLoading)
                .opacity(authManager.isLoading ? 0.6 : 1.0)
                
                Text("登录即表示您同意我们的服务条款和隐私政策")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
            
            if authManager.isLoading {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .alert("登录失败", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func signInWithGoogle() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        Task {
            do {
                try await authManager.signInWithGoogle(presentingViewController: rootViewController)
            } catch {
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
        }
    }
}

#Preview {
    LoginView()
}
