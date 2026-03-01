import Foundation
import Combine

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // 先全部免费：固定 free
    @Published var isLoading = false

    private init() {}

    // 保留同名接口，避免其他代码改动
    func refreshCustomerInfo() {}

    func fetchOfferings() async {}

    var currentPlan: String {
        "free"
    }

    var retentionDays: Int {
        7
    }

    func restorePurchases() async throws {}

    func syncUser(uid: String) {}
}
