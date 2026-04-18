import Foundation

enum AppConfig {
    // 默认统一走线上，避免 Debug 下误连 localhost:8080 导致无法翻译/识别
    static let httpBaseURL = URL(string: "https://talko-backend-production.up.railway.app")!
    static let wsRealtimeURL = URL(string: "wss://talko-backend-production.up.railway.app/api/v1/asr/realtime")!
    static let privacyPolicyURL = URL(string: "https://www.formeasily.com/privacy.html")!
}
