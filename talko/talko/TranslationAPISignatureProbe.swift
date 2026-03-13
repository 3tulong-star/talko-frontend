import Foundation
#if canImport(Translation)
import Translation
#endif

/// 用于在当前 Xcode/SDK 下快速探测 Translation.framework 的实际 API 签名。
/// 该文件不会影响现有业务逻辑。
enum TranslationAPISignatureProbe {
    static func runCompileProbe() {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            // 这里先只引用类型，确保模块可见。
            let _: TranslationSession? = nil
            let _: TranslationSession.Configuration? = nil

            // 下一步请在 Xcode 中对 `TranslationSession.Configuration` 和 `TranslationSession`
            // 使用 “Jump to Definition”，把真实构造器签名贴给我。
            // 我会据此把 ConversationViewModel 里的 localPreviewTranslate 精确补全。
        }
        #endif
    }
}
