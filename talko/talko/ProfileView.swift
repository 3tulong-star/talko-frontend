import SwiftUI
import FirebaseAuth

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var authManager = AuthManager.shared

    @State private var usageText: String = NSLocalizedString("usage_loading", comment: "")
    @State private var usageTextColor: Color = .secondary

    private let httpBase = URL(string: "https://tulong.zeabur.app")!
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
}

private struct ProfileUsageResponse: Decodable {
    let usageSecondsTotal: Int
    let usageLimitSeconds: Int
    let remainingSeconds: Int
}
