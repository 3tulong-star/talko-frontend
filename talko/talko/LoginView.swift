import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.pageBackground, Color.white],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Circle()
                .fill(AppTheme.googleBlue.opacity(0.10))
                .frame(width: 300, height: 300)
                .blur(radius: 44)
                .offset(x: -130, y: -320)

            VStack(spacing: 26) {
                Spacer(minLength: 14)

                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.subtleBlue)
                            .frame(width: 112, height: 112)

                        Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                            .symbolEffect(.bounce, value: authManager.isLoading)
                    }

                    Text("Talko")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue.opacity(0.95), .blue.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(NSLocalizedString("login_subtitle", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                }

                Spacer(minLength: 0)

                VStack(spacing: 12) {
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
                    .frame(height: 52)
                    .cornerRadius(16)

                    // Google Sign In
                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack(spacing: 12) {
                            Image("google_logo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)

                            Text(NSLocalizedString("login_google", comment: ""))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white)
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                        )
                    }

                    Button {
                        authManager.continueAsGuest()
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "person.fill.questionmark")
                            Text(NSLocalizedString("login_guest_mode", comment: ""))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.blue.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(.white.opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(Color.blue.opacity(0.14), lineWidth: 1)
                        )
                )
                .shadow(color: Color.blue.opacity(0.08), radius: 14, x: 0, y: 8)
                .padding(.horizontal, 18)
                .disabled(authManager.isLoading)
                .opacity(authManager.isLoading ? 0.65 : 1.0)

                Text(NSLocalizedString("login_terms", comment: ""))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            if authManager.isLoading {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView()
                    .scaleEffect(1.4)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .alert(NSLocalizedString("login_failed", comment: ""), isPresented: $showError) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) { }
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
