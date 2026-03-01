import Foundation

enum AppConfig {
    #if DEBUG
    static let httpBaseURL = URL(string: "http://localhost:8080")!
    static let wsRealtimeURL = URL(string: "ws://localhost:8080/api/v1/asr/realtime")!
    #else
    static let httpBaseURL = URL(string: "https://tulong.zeabur.app")!
    static let wsRealtimeURL = URL(string: "wss://tulong.zeabur.app/api/v1/asr/realtime")!
    #endif
}
