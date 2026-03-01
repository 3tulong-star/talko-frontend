import Foundation
import Combine
import FirebaseAuth
import AuthenticationServices
import CryptoKit
import GoogleSignIn

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var user: User?
    @Published var isLoading = false
    
    private var currentNonce: String?
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    
    init() {
        self.user = Auth.auth().currentUser
        
        // 监听登录状态变化
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
            }
        }
    }

    deinit {
        if let authStateHandle {
            Auth.auth().removeStateDidChangeListener(authStateHandle)
        }
    }
    
    var isAuthenticated: Bool {
        return user != nil
    }
    
    func getIDToken() async -> String? {
        guard let user = user else { return nil }
        do {
            return try await user.getIDToken()
        } catch {
            print("Error getting ID token: \(error.localizedDescription)")
            return nil
        }
    }
    
    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            print("Error signing out: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Apple Sign In
    
    func startAppleSignIn() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return sha256(nonce)
    }
    
    func handleAppleSignIn(credential: ASAuthorizationAppleIDCredential) async throws {
        guard let nonce = currentNonce else {
            throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid nonce state"])
        }
        
        guard let appleIDToken = credential.identityToken else {
            throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to fetch identity token"])
        }
        
        guard let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to serialize token string from data"])
        }
        
        let firebaseCredential = OAuthProvider.appleCredential(withIDToken: idTokenString,
                                                              rawNonce: nonce,
                                                              fullName: credential.fullName)
        
        isLoading = true
        defer { isLoading = false }
        
        try await Auth.auth().signIn(with: firebaseCredential)
    }
    
    // MARK: - Google Sign In
    
    func signInWithGoogle(presentingViewController: UIViewController) async throws {
        isLoading = true
        defer { isLoading = false }
        
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
        
        guard let idToken = result.user.idToken?.tokenString else {
            throw NSError(domain: "AuthManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Google Sign In failed: No ID Token"])
        }
        
        let accessToken = result.user.accessToken.tokenString
        
        let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                       accessToken: accessToken)
        
        try await Auth.auth().signIn(with: credential)
    }
    
    // MARK: - Helpers
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var result = ""
        var remainingLength = length
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        
        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
            
            randoms.forEach { random in
                if remainingLength == 0 { return }
                
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        
        return result
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap { String(format: "%02x", $0) }.joined()
        return hashString
    }
}
