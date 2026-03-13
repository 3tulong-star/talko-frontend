import Foundation

enum ASRProvider: String {
    case qwen
    case openai
    case deepgram
}

enum TranslationProvider: String {
    case doubao
    case openai
    case minimax
    case gemini
}

enum TTSProvider: String {
    case apple
    case qwen
}

struct ModelRouting {
    let asrProvider: ASRProvider
    let asrModel: String
    let translationProvider: TranslationProvider
    let ttsProvider: TTSProvider
    let ttsVoiceLocale: String
}

enum ProviderRouter {
    static func route(
        source: String,
        target: String,
        asrOverride: String? = nil,
        translateOverride: String? = nil,
        ttsOverride: String? = nil
    ) -> ModelRouting {
        let pair = "\(source)->\(target)"

        let defaultASRProvider: ASRProvider = .qwen
        let defaultASRModel = "qwen3-asr-flash-realtime-2026-02-10"
        let defaultTranslationProvider: TranslationProvider = .gemini
        let defaultTTSProvider: TTSProvider = .qwen

        let asrProvider = ASRProvider(rawValue: (asrOverride ?? "").lowercased()) ?? defaultASRProvider
        let translationProvider = TranslationProvider(rawValue: (translateOverride ?? "").lowercased()) ?? defaultTranslationProvider
        let ttsProvider = TTSProvider(rawValue: (ttsOverride ?? "").lowercased()) ?? defaultTTSProvider

        let localeMap: [String: String] = [
            "zh": "zh-CN", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR",
            "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "it": "it-IT",
            "pt": "pt-PT", "ru": "ru-RU", "ar": "ar-SA", "hi": "hi-IN",
            "id": "id-ID", "th": "th-TH", "tr": "tr-TR", "uk": "uk-UA",
            "vi": "vi-VN", "cs": "cs-CZ", "da": "da-DK", "fil": "fil-PH",
            "fi": "fi-FI", "is": "is-IS", "ms": "ms-MY", "no": "nb-NO",
            "pl": "pl-PL", "sv": "sv-SE"
        ]

        let asrModel: String
        switch asrProvider {
        case .qwen:
            asrModel = defaultASRModel
        case .openai:
            asrModel = "gpt-4o-transcribe"
        case .deepgram:
            asrModel = "nova-3"
        }

        let ttsLocale = localeMap[target] ?? "en-US"

        // 预留按语言对细分路由能力
        _ = pair

        return ModelRouting(
            asrProvider: asrProvider,
            asrModel: asrModel,
            translationProvider: translationProvider,
            ttsProvider: ttsProvider,
            ttsVoiceLocale: ttsLocale
        )
    }
}
