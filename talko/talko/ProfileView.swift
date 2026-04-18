import SwiftUI
import FirebaseAuth

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var authManager = AuthManager.shared

    @State private var usageText: String = NSLocalizedString("usage_loading", comment: "")
    @State private var usageTextColor: Color = .secondary
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deletionErrorMessage: String?

    private let httpBase = AppConfig.httpBaseURL
    let onSignedOut: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.blue)

                    Text(Auth.auth().currentUser?.email ?? NSLocalizedString("profile_no_email", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("profile_usage_title", comment: ""))
                        .font(.headline)
                    Text(usageText)
                        .font(.subheadline)
                        .foregroundColor(usageTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)

                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("profile_account_section", comment: ""))
                        .font(.headline)

                    Link(NSLocalizedString("privacy_policy", comment: ""), destination: AppConfig.privacyPolicyURL)
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)

                Button(role: .destructive) {
                    authManager.signOut()
                    onSignedOut()
                    dismiss()
                } label: {
                    Text(NSLocalizedString("logout", comment: ""))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    if isDeletingAccount {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    } else {
                        Text(NSLocalizedString("delete_account", comment: ""))
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isDeletingAccount)

                Spacer()
            }
            .padding()
            .navigationTitle(NSLocalizedString("profile", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("done", comment: "")) { dismiss() }
                }
            }
            .task {
                await refreshUsage()
            }
            .alert(NSLocalizedString("delete_account_title", comment: ""), isPresented: $showDeleteConfirmation) {
                Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
                Button(NSLocalizedString("delete_account_confirm", comment: ""), role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text(NSLocalizedString("delete_account_message", comment: ""))
            }
            .alert(
                NSLocalizedString("delete_account_failed_title", comment: ""),
                isPresented: Binding(
                    get: { deletionErrorMessage != nil },
                    set: { if !$0 { deletionErrorMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
            } message: {
                Text(deletionErrorMessage ?? "")
            }
        }
    }

    private func refreshUsage() async {
        if AuthManager.shared.isGuestMode {
            usageText = NSLocalizedString("usage_guest", comment: "")
            usageTextColor = .orange
            return
        }

        guard let token = await AuthManager.shared.getIDToken() else {
            usageText = NSLocalizedString("usage_not_logged_in", comment: "")
            usageTextColor = .red
            return
        }

        var req = URLRequest(url: httpBase.appendingPathComponent("/api/v1/usage/me"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                usageText = NSLocalizedString("usage_failed_network", comment: "")
                usageTextColor = .red
                return
            }

            let decoded = try JSONDecoder().decode(ProfileUsageResponse.self, from: data)
            let remainMin = Int(ceil(Double(max(0, decoded.remainingSeconds)) / 60.0))
            let usedMin = Int(decoded.usageSecondsTotal / 60)
            let limitMin = Int(decoded.usageLimitSeconds / 60)
            usageText = String(format: NSLocalizedString("usage_summary", comment: ""), usedMin, limitMin, remainMin)
            usageTextColor = remainMin > 0 ? .secondary : .red
        } catch {
            usageText = NSLocalizedString("usage_failed_network", comment: "")
            usageTextColor = .red
        }
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await authManager.deleteCurrentAccount()
            onSignedOut()
            dismiss()
        } catch {
            let nsError = error as NSError
            if nsError.domain == AuthErrorDomain,
               nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
                deletionErrorMessage = NSLocalizedString("delete_account_requires_recent_login", comment: "")
            } else {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct ProfileUsageResponse: Decodable {
    let usageSecondsTotal: Int
    let usageLimitSeconds: Int
    let remainingSeconds: Int
}
