import SwiftUI
import Combine
import AVFoundation

@MainActor
final class ConversationViewModel: ObservableObject {
    private let wsURL = AppConfig.wsRealtimeURL
    private let httpBase = AppConfig.httpBaseURL

    @Published var langA: LangOption = supportedLangs.first(where: { $0.id == "zh" })!
    @Published var langB: LangOption = supportedLangs.first(where: { $0.id == "en" })!

    @Published var autoSpeak: Bool = true
    @Published var isHoldingA = false
    @Published var isHoldingB = false
    @Published var isHoldingSingle = false
    @Published var isLiveActive = false
    @Published var messages: [ChatMessage] = []

    // 模式：双按钮, 单按钮, 或 Live
    @Published var mode: ConversationMode = .dualButton

    // 控制语言选择弹窗
    @Published var showingPickerA = false
    @Published var showingPickerB = false

    private let wsClient = RealtimeWSClient()
    private let streamer = AudioStreamer()
    private let tts = AVSpeechSynthesizer()

    private var activeSide: Side? = nil
    private var activeMsgId: UUID? = nil

    // MARK: - Debug info
    private var holdStartedAt: Date? = nil

    private func log(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let ts = formatter.string(from: Date())
        print("[VM][\(ts)] \(msg)")
    }

    // MARK: - Finalize control
    private var isFinalizing: Bool = false

    // MARK: - Live idle timeout
    private var liveIdleTask: Task<Void, Never>? = nil
    private var liveLastActivityAt: Date = Date()
    private let liveIdleTimeoutSeconds: TimeInterval = 30

    init() {
        setupCallbacks()
    }

    private func setupCallbacks() {
        streamer.onAudioBuffer = { [weak self] base64 in
            self?.wsClient.sendAudio(base64: base64)
        }

        wsClient.onPartialText = { [weak self] text in
            Task { @MainActor in self?.applyPartial(text) }
        }

        // 用于 Live 模式的闲置超时：在检测到有效语音事件时重置计时
        wsClient.onPartialEvent = { [weak self] event in
            Task { @MainActor in self?.handleLiveActivityEvent(event) }
        }

        wsClient.onFinalEvent = { [weak self] event in
            Task { @MainActor in await self?.applyFinalEvent(event) }
        }

        wsClient.onError = { msg in
            print("WS error:", msg)
        }
    }

    // MARK: - UI events

    func pressAChanged(_ pressing: Bool) {
        guard mode == .dualButton else { return }
        isHoldingA = pressing
        if pressing {
            holdStartedAt = Date()
            log("A press down")
            start(side: .a)
        } else {
            let dur = holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            log(String(format: "A press up (held %.2fs)", dur))
            holdStartedAt = nil
            stopAndFinalize()
        }
    }

    func pressBChanged(_ pressing: Bool) {
        guard mode == .dualButton else { return }
        isHoldingB = pressing
        if pressing {
            holdStartedAt = Date()
            log("B press down")
            start(side: .b)
        } else {
            let dur = holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            log(String(format: "B press up (held %.2fs)", dur))
            holdStartedAt = nil
            stopAndFinalize()
        }
    }

    func singlePressChanged(_ pressing: Bool) {
        guard mode == .singleButton else { return }
        isHoldingSingle = pressing
        if pressing {
            holdStartedAt = Date()
            log("Single button press down")
            startSingleButton()
        } else {
            let dur = holdStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            log(String(format: "Single button press up (held %.2fs)", dur))
            holdStartedAt = nil
            stopAndFinalize()
        }
    }

    func toggleLive() {
        guard mode == .live else { return }
        if isLiveActive {
            log("Stopping Live mode")
            isLiveActive = false
            stopLiveAndFinalize()
        } else {
            log("Starting Live mode")
            isLiveActive = true
            startLive()
        }
    }

    func swapLanguages() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()

        log("Swapping languages: \(langA.name) <-> \(langB.name)")
        let temp = langA
        langA = langB
        langB = temp
    }

    func speakMessage(_ m: ChatMessage) {
        guard let text = m.translated, !text.isEmpty else { return }
        let target = (m.side == .a) ? langB.id : langA.id
        speak(text: text, lang: target)
    }

    // MARK: - ASR core

    private func start(side: Side) {
        guard activeSide == nil, isFinalizing == false else { return }

        activeSide = side
        let msg = ChatMessage(side: side)
        messages.append(msg)
        activeMsgId = msg.id

        let wsMode = mode == .dualButton ? "dual_button" : (mode == .singleButton ? "single_button" : "live")
        let cfg = RealtimeConfig(mode: wsMode, leftLang: langA.id, rightLang: langB.id)

        Task { [weak self] in
            guard let self else { return }
            guard let authedWsURL = await self.authorizedRealtimeWsURL() else {
                self.log("Missing Firebase token, cannot open realtime WS")
                self.cleanupSession()
                return
            }
            self.log("WS connecting (\(wsMode)) left=\(self.langA.id) right=\(self.langB.id)")
            self.wsClient.connect(url: authedWsURL, config: cfg)
        }

        do {
            try streamer.start()
            log("Streamer started")
        } catch {
            log("Audio start error: \(error)")
        }
    }

    private func startSingleButton() {
        start(side: .a)
    }

    private func startLive() {
        // Live 模式不需要预设 side，因为靠服务端 VAD 自动返回 ui_side
        let cfg = RealtimeConfig(mode: "live", leftLang: langA.id, rightLang: langB.id)

        Task { [weak self] in
            guard let self else { return }
            guard let authedWsURL = await self.authorizedRealtimeWsURL() else {
                self.log("Missing Firebase token, cannot open realtime WS (live)")
                self.cleanupSession()
                return
            }
            self.log("WS connecting (live) left=\(self.langA.id) right=\(self.langB.id)")
            self.wsClient.connect(url: authedWsURL, config: cfg)
        }

        // 启动 Live 闲置超时计时
        resetLiveIdleTimer()

        do {
            try streamer.start()
            log("Streamer started (live)")
        } catch {
            log("Audio start error (live): \(error)")
        }
    }

    private func resetLiveIdleTimer() {
        liveLastActivityAt = Date()
        liveIdleTask?.cancel()
        liveIdleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 每秒检查
                if Date().timeIntervalSince(liveLastActivityAt) >= liveIdleTimeoutSeconds {
                    log("Live mode idle timeout (30s), stopping...")
                    await MainActor.run {
                        if isLiveActive {
                            isLiveActive = false
                            stopLiveAndFinalize()
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleLiveActivityEvent(_ event: [String: Any]) {
        guard mode == .live, isLiveActive else { return }
        
        let type = event["type"] as? String ?? ""
        // 定义哪些事件算作“有效活动”
        let activityTypes = [
            "input_audio_buffer.speech_started",
            "conversation.item.input_audio_transcription.text",
            "conversation.item.input_audio_transcription.completed"
        ]
        
        if activityTypes.contains(type) {
            liveLastActivityAt = Date()
        }
    }

    private func stopAndFinalize() {
        log("Stopping streamer and finishing WS (wait final)")
        streamer.stop()
        isFinalizing = true
        wsClient.commit() // Manual 模式需要先 commit
        wsClient.finish() // 再发 session.finish

        startFinalTimeout()
    }

    private func stopLiveAndFinalize() {
        log("Stopping streamer and finishing WS (live mode)")
        streamer.stop()
        // VAD 模式直接发 finish 即可，服务端会处理完缓冲区并返回最终结果
        wsClient.finish()
        
        startFinalTimeout()
    }

    private func startFinalTimeout() {
        isFinalizing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.isFinalizing {
                self.log("Final timeout, force disconnect")
                self.isFinalizing = false
                self.cleanupSession()
            }
        }
    }

    func cleanupSession() {
        streamer.stop()
        wsClient.disconnect()
        activeSide = nil
        activeMsgId = nil
        isHoldingA = false
        isHoldingB = false
        isHoldingSingle = false
        isLiveActive = false
    }

    private func applyPartial(_ text: String) {
        guard !text.isEmpty else { return }
        
        // 查找或创建活动消息
        if let id = activeMsgId, let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].originalPartial = text
        } else {
            // 对 Live 模式，当收到第一个 partial 时创建一条新消息
            let msg = ChatMessage(side: .a) // 默认 side，等 completed 修正
            messages.append(msg)
            activeMsgId = msg.id
            messages[messages.count-1].originalPartial = text
        }
    }

    private func applyFinalEvent(_ event: [String: Any]) async {
        let evType = event["type"] as? String ?? ""
        log("ASR Event received: \(evType)")
        
        if evType == "session.finished" {
            log("Session finished by server")
            isFinalizing = false
            cleanupSession()
            return
        }

        // 处理 completed 事件
        if evType == "conversation.item.input_audio_transcription.completed" {
            guard let transcript = event["transcript"] as? String, !transcript.isEmpty else {
                // 如果是 Live 模式且当前正在 finalize，且没有更多内容，则可以清理了
                if mode == .live && isFinalizing {
                    cleanupSession()
                }
                return 
            }

            let uiSideStr = event["ui_side"] as? String ?? "left"
            let source = event["ui_source_lang"] as? String ?? langA.id
            let target = event["ui_target_lang"] as? String ?? langB.id
            let side: Side = (uiSideStr == "right") ? .b : .a

            await processFinalResult(transcript: transcript, side: side, source: source, target: target)

            if mode != .live {
                isFinalizing = false
                cleanupSession()
            } else {
                // Live 模式保持连接，清除当前消息 ID 引用，以便下一句开启新气泡
                activeMsgId = nil
                if isFinalizing {
                    cleanupSession()
                }
            }
        }
    }

    private func processFinalResult(transcript: String, side: Side, source: String, target: String) async {
        // 找到当前正在 partial 的消息并固定它，或者新建
        if let id = activeMsgId, let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].side = side
            messages[idx].originalFinal = transcript
            messages[idx].originalPartial = ""
            await translateAndOptionallySpeak(index: idx, source: source, target: target)
        } else {
            let m = ChatMessage(side: side)
            messages.append(m)
            let lastIdx = messages.count - 1
            messages[lastIdx].originalFinal = transcript
            await translateAndOptionallySpeak(index: lastIdx, source: source, target: target)
        }
    }

    private func translateAndOptionallySpeak(index: Int, source: String, target: String) async {
        let text = messages[index].originalFinal ?? ""
        do {
            log("Translating (\(source) -> \(target))...")
            let translated = try await translate(text: text, source: source, target: target)
            messages[index].translated = translated
            
            // Live 模式不自动播放 TTS
            if autoSpeak && mode != .live {
                speak(text: translated, lang: target)
            }
        } catch {
            log("Translate error: \(error)")
            messages[index].translated = "[翻译失败]"
        }
    }

    private func authorizedRealtimeWsURL() async -> URL? {
        guard let token = await AuthManager.shared.getIDToken() else { return nil }
        guard var c = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else { return nil }

        var items = c.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: token))
        c.queryItems = items

        return c.url
    }

    private func translate(text: String, source: String, target: String) async throws -> String {
        let endpoint = httpBase.appendingPathComponent("/api/v1/translate/text")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "source_lang": source,
            "target_lang": target,
            "stream": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Translate", code: 1)
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["translation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speak(text: String, lang: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.5
        let locale = (lang == "zh") ? "zh-CN" : (lang == "ja" ? "ja-JP" : (lang == "ko" ? "ko-KR" : "en-US"))
        u.voice = AVSpeechSynthesisVoice(language: locale)
        tts.speak(u)
    }
}
