import Foundation
import Combine

struct Conversation: Identifiable, Codable {
    let id: String
    let title: String?
    let langLeft: String
    let langRight: String
    let createdAt: Date
    let updatedAt: Date
    let lastMessageAt: Date?
    let isArchived: Bool
    let expireAt: Date?
}

struct HistoryMessage: Identifiable, Codable {
    let id: String
    let side: String
    let sourceLang: String
    let targetLang: String
    let originalText: String
    let translatedText: String?
    let createdAt: Date
    let expireAt: Date?
}

@MainActor
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    private let httpBase = URL(string: "https://tulong.zeabur.app")!
    
    @Published var conversations: [Conversation] = []
    @Published var isLoading = false
    
    private func getHeaders() async -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let token = await AuthManager.shared.getIDToken() {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }
    
    func createConversation(langLeft: String, langRight: String, title: String? = nil) async throws -> String {
        let endpoint = httpBase.appendingPathComponent("/api/v1/history/conversations")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        for (key, value) in await getHeaders() {
            req.setValue(value, forHTTPHeaderField: key)
        }
        
        let body: [String: Any] = [
            "langLeft": langLeft,
            "langRight": langRight,
            "title": title as Any
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["conversationId"] as? String ?? ""
    }
    
    func saveMessage(conversationId: String, side: String, sourceLang: String, targetLang: String, originalText: String, translatedText: String?) async throws {
        let endpoint = httpBase.appendingPathComponent("/api/v1/history/conversations/\(conversationId)/messages")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        for (key, value) in await getHeaders() {
            req.setValue(value, forHTTPHeaderField: key)
        }
        
        let body: [String: Any] = [
            "side": side,
            "sourceLang": sourceLang,
            "targetLang": targetLang,
            "originalText": originalText,
            "translatedText": translatedText as Any
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        _ = try await URLSession.shared.data(for: req)
    }
    
    func fetchConversations() async {
        isLoading = true
        defer { isLoading = false }
        
        let endpoint = httpBase.appendingPathComponent("/api/v1/history/conversations")
        var req = URLRequest(url: endpoint)
        for (key, value) in await getHeaders() {
            req.setValue(value, forHTTPHeaderField: key)
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601 // 假设后端返回 ISO8601 格式
            let wrapper = try decoder.decode([String: [Conversation]].self, from: data)
            self.conversations = wrapper["conversations"] ?? []
        } catch {
            print("Fetch conversations error: \(error)")
        }
    }
}
