import Foundation

enum AppConfig {
    // 默认统一走线上，避免 Debug 下误连 localhost:8080 导致无法翻译/识别
    static let httpBaseURL = URL(string: "https://tulong.zeabur.app")!
    static let wsRealtimeURL = URL(string: "wss://tulong.zeabur.app/api/v1/asr/realtime")!
}
