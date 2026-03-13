import Foundation

enum Side {
    case a
    case b
}

enum ConversationMode {
    case dualButton   // A/B 双按钮模式
    case singleButton // 单按钮模式（ASR 自动识别语言）
    case live         // Live 模式（自由说话，持续识别分句）
}

struct LangOption: Identifiable, Equatable, Hashable {
    let id: String

    // 按当前系统语言自动本地化语言名称（例如系统中文下显示“德语”，英文下显示“German”）
    var name: String {
        Locale.current.localizedString(forLanguageCode: id)?.capitalized
        ?? Locale(identifier: "en").localizedString(forLanguageCode: id)?.capitalized
        ?? id
    }

    // 按钮文案保持简短，避免多语言下过长
    var holdToTalkText: String {
        NSLocalizedString("hold_to_talk_short", comment: "")
    }
}

let supportedLangs: [LangOption] = [
    .init(id: "zh"),
    .init(id: "en"),
    .init(id: "ja"),
    .init(id: "de"),
    .init(id: "ko"),
    .init(id: "ru"),
    .init(id: "fr"),
    .init(id: "pt"),
    .init(id: "ar"),
    .init(id: "it"),
    .init(id: "es"),
    .init(id: "hi"),
    .init(id: "id"),
    .init(id: "th"),
    .init(id: "tr"),
    .init(id: "uk"),
    .init(id: "vi"),
    .init(id: "cs"),
    .init(id: "da"),
    .init(id: "fil"),
    .init(id: "fi"),
    .init(id: "is"),
    .init(id: "ms"),
    .init(id: "no"),
    .init(id: "pl"),
    .init(id: "sv")
]

let qwenSupportedLangIds: Set<String> = [
    "zh", "en", "ja", "de", "ko", "ru", "fr", "pt", "ar", "it", "es",
    "hi", "id", "th", "tr", "uk", "vi", "cs", "da", "fil", "fi", "is",
    "ms", "no", "pl", "sv"
]

let qwenSupportedLangs: [LangOption] = supportedLangs.filter { qwenSupportedLangIds.contains($0.id) }

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var side: Side
    var originalPartial: String
    var originalFinal: String?
    var translated: String?

    var sourceLang: String?
    var targetLang: String?

    var asrProvider: String?
    var asrModel: String?
    var translationProvider: String?
    var translationModel: String?
    var ttsProvider: String?
    var ttsModel: String?

    // Per-sentence metrics (for Live test page)
    var asrMs: Int?
    var translateMs: Int?
    var ttsMs: Int?
    var totalMs: Int?

    init(side: Side) {
        self.id = UUID()
        self.side = side
        self.originalPartial = ""
        self.originalFinal = nil
        self.translated = nil
        self.sourceLang = nil
        self.targetLang = nil
        self.asrProvider = nil
        self.asrModel = nil
        self.translationProvider = nil
        self.translationModel = nil
        self.ttsProvider = nil
        self.ttsModel = nil
        self.asrMs = nil
        self.translateMs = nil
        self.ttsMs = nil
        self.totalMs = nil
    }
}
