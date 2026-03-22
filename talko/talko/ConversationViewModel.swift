import SwiftUI
import Combine
import AVFoundation
#if canImport(Translation)
import Translation
#endif

struct InteractionMetrics {
    var sentenceId: String = "-"
    var asrMs: Int? = nil
    var translateMs: Int? = nil
    var ttsMs: Int? = nil
    var totalMs: Int? = nil
}

@MainActor
final class ConversationViewModel: NSObject, ObservableObject {
    private let wsURL = AppConfig.wsRealtimeURL
    private let httpBase = AppConfig.httpBaseURL

    @Published var langA: LangOption
    @Published var langB: LangOption

    @Published var autoSpeak: Bool = true
    @Published var isHoldingA = false
    @Published var isHoldingB = false
    @Published var isHoldingSingle = false
    @Published var isLiveActive = false
    @Published var isLivePlaybackPaused = false
    @Published var messages: [ChatMessage] = []
    @Published var latestMetrics: InteractionMetrics = InteractionMetrics()

    // 模式：双按钮, 单按钮, 或 Live
    @Published var mode: ConversationMode = .dualButton

    // 控制语言选择弹窗
    @Published var showingPickerA = false
    @Published var showingPickerB = false

    private let wsClient = RealtimeWSClient()
    private let streamer = AudioStreamer()
    private let tts = AVSpeechSynthesizer()
    private var qwenAudioPlayer: AVAudioPlayer? = nil
    private let qwenAudioEngine = AVAudioEngine()
    private let qwenAudioNode = AVAudioPlayerNode()
    private var qwenAudioEngineReady = false
    private var qwenStreamActive = false
    private let liveDebugLogs: Bool = true
    private var previewTranslateTask: Task<Void, Never>? = nil
    private var lastPreviewSourceTextByMessage: [UUID: String] = [:]
    private var previewTranslatedMessageIds: Set<UUID> = []
    private var livePendingSideByItemId: [String: Side] = [:]
    private var livePendingLangByItemId: [String: (String, String)] = [:]
    private var livePendingMessageIdByItemId: [String: UUID] = [:]
    private var lastLivePartialItemId: String? = nil
    private let useLocalPreviewTranslation = true
    private let useGooglePreviewTranslation = true

    // 可由外部参数覆盖（例如 A/B 实验）
    var asrProviderOverride: String? = nil
    var translationProviderOverride: String? = nil
    var ttsProviderOverride: String? = nil
    var asrModelOverride: String? = nil
    var translationModelOverride: String? = nil
    var ttsModelOverride: String? = nil
    // 暂时保留调试参数，当前已不再启用 echo guard / barge-in。
    var liveBargeInEnabled: Bool = false
    var liveRmsThreshold: Double = 0.008
    var liveMinSpeechMs: Double = 120
    var liveMaxSilenceMs: Double = 450
    var liveLogRmsSamples: Bool = false
    var liveDuckGain: Double = 0.20

    private var activeSide: Side? = nil
    private var activeMsgId: UUID? = nil

    // MARK: - Debug info
    private var holdStartedAt: Date? = nil
    private var sentenceStartedAtMap: [String: Date] = [:]

    private func log(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let ts = formatter.string(from: Date())
        print("[VM][\(ts)] \(msg)")
    }

    // MARK: - Finalize control
    private var isFinalizing: Bool = false
    private var finalTimeoutTask: Task<Void, Never>? = nil

    private struct LivePlaybackContext {
        let token: UUID
        let messageId: UUID
        let sentenceId: String
        let asrMs: Int?
        let translateMs: Int?
        let totalBeforeTts: Int
        var ttsProvider: String?
        var ttsModel: String?
        let startedAt: Date
    }
    private var livePlaybackContext: LivePlaybackContext? = nil
    private var livePlaybackTask: Task<Void, Never>? = nil
    private var liveStreamerSuspendedForPlayback = false

    // MARK: - Live state machine
    private enum LiveState {
        case idle
        case connecting
        case active
        case playbackPaused
        case stopping
    }
    private var liveState: LiveState = .idle
    private var liveSessionId: UUID = UUID()
    private var liveStartCooldownUntil: Date = .distantPast

    // MARK: - Live idle timeout
    private var liveIdleTask: Task<Void, Never>? = nil
    private var liveLastActivityAt: Date = Date()
    private let liveIdleTimeoutSeconds: TimeInterval = 30

    override init() {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = Locale(identifier: preferred).languageCode ?? "en"
        let normalized = (code == "zh") ? "zh" : code

        let defaultLeft = supportedLangs.first(where: { $0.id == normalized })
            ?? supportedLangs.first(where: { $0.id == "en" })
            ?? supportedLangs[0]

        let defaultRight = supportedLangs.first(where: { $0.id == "en" }) ?? supportedLangs[0]

        _langA = Published(initialValue: defaultLeft)
        _langB = Published(initialValue: defaultRight.id == defaultLeft.id
            ? (supportedLangs.first(where: { $0.id != defaultLeft.id }) ?? defaultLeft)
            : defaultRight)

        super.init()
        tts.delegate = self
        setupCallbacks()
    }

    private func configureLiveListeningAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP])
            try session.setActive(true, options: [])
            try session.overrideOutputAudioPort(.speaker)
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            log("[Audio][live] listening category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=\(outputs) inputs=\(inputs)")
        } catch {
            log("[Audio][live] listening config failed: \(error.localizedDescription)")
        }
    }

    private func configureLivePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            log("[Audio][live] playback category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=\(outputs)")
        } catch {
            log("[Audio][live] playback config failed: \(error.localizedDescription)")
        }
    }

    private func restoreDefaultAudioSessionAfterLive() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            log("[Audio][live] restored category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=\(outputs) inputs=\(inputs)")
        } catch {
            log("[Audio][live] restore failed: \(error.localizedDescription)")
        }
    }

    private func setupCallbacks() {
        streamer.onAudioBuffer = { [weak self] base64 in
            guard let self else { return }

            if self.mode == .live && self.isLivePlaybackPaused {
                return
            }

            self.wsClient.sendAudio(base64: base64)
        }

        wsClient.onPartialText = { [weak self] text in
            Task { @MainActor in self?.applyPartial(text) }
        }

        // 用于 Live 模式的闲置超时：在检测到有效语音事件时重置计时
        wsClient.onPartialEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleLiveActivityEvent(event)
                self?.applyPartialEvent(event)
            }
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

        switch liveState {
        case .idle:
            guard Date() >= liveStartCooldownUntil else {
                log("Live start blocked by cooldown")
                return
            }
            log("Starting Live mode")
            isLiveActive = true
            liveState = .connecting
            liveSessionId = UUID()
            startLive(sessionId: liveSessionId)

        case .connecting, .active:
            log("Stopping Live mode")
            isLiveActive = false
            liveState = .stopping
            stopLiveAndFinalize()

        case .playbackPaused:
            log("Stopping Live mode from playback paused state")
            isLiveActive = false
            liveState = .stopping
            stopLiveAndFinalize()

        case .stopping:
            log("Live is stopping, ignore toggle")
        }
    }

    func resumeLiveManually() {
        guard mode == .live, isLiveActive, isLivePlaybackPaused else { return }
        stopCurrentLivePlayback(resetState: false)
        guard resumeLiveListeningAfterPlayback() else {
            log("[Audio][live] manual resume failed to restart listener")
            liveState = .idle
            cleanupSession(stopPlayback: false)
            return
        }
        isLivePlaybackPaused = false
        liveState = .active
        resetLiveIdleTimer()
        log("[LiveFlow] playback_resumed manually")
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
        let route = ProviderRouter.route(
            source: m.side == .a ? langA.id : langB.id,
            target: target,
            asrOverride: asrProviderOverride,
            translateOverride: translationProviderOverride,
            ttsOverride: ttsProviderOverride
        )

        if mode == .live, isLiveActive {
            startLivePlayback(
                text: text,
                targetLang: target,
                locale: route.ttsVoiceLocale,
                provider: route.ttsProvider,
                messageId: m.id,
                sentenceId: m.id.uuidString,
                asrMs: m.asrMs,
                translateMs: m.translateMs,
                totalBeforeTts: m.totalMs ?? ((m.asrMs ?? 0) + (m.translateMs ?? 0))
            )
            return
        }

        Task {
            _ = await speak(text: text, targetLang: target, provider: route.ttsProvider, locale: route.ttsVoiceLocale)
        }
    }

    // MARK: - ASR core

    private func start(side: Side, createInitialMessage: Bool = true) {
        guard activeSide == nil, isFinalizing == false else { return }

        // 单/双按钮使用默认播放会话，不走 live AEC 会话
        restoreDefaultAudioSessionAfterLive()

        activeSide = side
        if createInitialMessage {
            let msg = ChatMessage(side: side)
            messages.append(msg)
            activeMsgId = msg.id
        } else {
            activeMsgId = nil
        }

        let wsMode = mode == .dualButton ? "dual_button" : (mode == .singleButton ? "single_button" : "live")
        let route = ProviderRouter.route(
            source: langA.id,
            target: langB.id,
            asrOverride: asrProviderOverride,
            translateOverride: translationProviderOverride,
            ttsOverride: ttsProviderOverride
        )
        let cfg = RealtimeConfig(
            mode: wsMode,
            leftLang: langA.id,
            rightLang: langB.id,
            asrProvider: route.asrProvider.rawValue,
            asrModel: route.asrModel
        )

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
        start(side: .a, createInitialMessage: false)
    }

    private func startLive(sessionId: UUID) {
        // live 模式保持当前 autoSpeak 设置；若开启则在播报期间暂停收音。
        // live 模式：不再启用 AEC 特殊会话（保持默认音频路由/音量表现）
        let route = ProviderRouter.route(
            source: langA.id,
            target: langB.id,
            asrOverride: asrProviderOverride,
            translateOverride: translationProviderOverride,
            ttsOverride: ttsProviderOverride
        )
        let cfg = RealtimeConfig(
            mode: "live",
            leftLang: langA.id,
            rightLang: langB.id,
            asrProvider: route.asrProvider.rawValue,
            asrModel: asrModelOverride ?? route.asrModel
        )

        log("[Route] mode=live pair=\(langA.id)->\(langB.id) asr=\(route.asrProvider.rawValue)(\(route.asrModel)) trans=\(route.translationProvider.rawValue) tts=\(route.ttsProvider.rawValue)")

        Task { [weak self] in
            guard let self else { return }
            guard sessionId == self.liveSessionId else { return }

            guard let authedWsURL = await self.authorizedRealtimeWsURL() else {
                self.log("Missing Firebase token, cannot open realtime WS (live)")
                self.liveState = .idle
                self.cleanupSession()
                return
            }

            guard sessionId == self.liveSessionId else { return }
            self.log("WS connecting (live) left=\(self.langA.id) right=\(self.langB.id) sid=\(sessionId.uuidString.prefix(8))")
            self.wsClient.connect(url: authedWsURL, config: cfg)
            self.liveState = .active
            self.resetLiveIdleTimer()
        }

        do {
            configureLiveListeningAudioSession()
            try streamer.start(preserveCurrentSession: true)
            liveStreamerSuspendedForPlayback = false
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            log("[Audio][live] streamer started with category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=\(outputs)")
            log("Streamer started (live)")
        } catch {
            log("Audio start error (live): \(error)")
            liveState = .idle
            cleanupSession()
        }
    }

    private func resetLiveIdleTimer() {
        liveLastActivityAt = Date()
        liveIdleTask?.cancel()
        liveIdleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 每秒检查
                if self.isLivePlaybackPaused {
                    continue
                }
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
        guard mode == .live, isLiveActive, !isLivePlaybackPaused else { return }
        
        let type = event["type"] as? String ?? ""
        // 定义哪些事件算作“有效活动”
        let activityTypes = [
            "input_audio_buffer.speech_started",
            "conversation.item.input_audio_transcription.text",
            "conversation.item.input_audio_transcription.completed"
        ]

        if type == "input_audio_buffer.speech_started",
           let itemId = event["item_id"] as? String {
            sentenceStartedAtMap[itemId] = Date()
        }

        if type == "conversation.item.input_audio_transcription.text",
           let itemId = event["item_id"] as? String {
            let uiSideStr = event["ui_side"] as? String ?? "left"
            let source = event["ui_source_lang"] as? String
            let target = event["ui_target_lang"] as? String
            let side: Side = (uiSideStr == "right") ? .b : .a
            if let source, let target {
                livePendingLangByItemId[itemId] = (source, target)
            }
            livePendingSideByItemId[itemId] = side
        }

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

        let route = ProviderRouter.route(
            source: langA.id,
            target: langB.id,
            asrOverride: asrProviderOverride,
            translateOverride: translationProviderOverride,
            ttsOverride: ttsProviderOverride
        )

        // OpenAI: 仅 commit，避免 commit+finish 并发导致空转写/竞态
        // Qwen: 直接 finish 即可
        if route.asrProvider == .openai {
            wsClient.commit()
        } else {
            wsClient.finish()
        }

        startFinalTimeout()
    }

    private func startFinalTimeout() {
        isFinalizing = true
        finalTimeoutTask?.cancel()

        // OpenAI ASR 与长句 live 的 final 返回时间通常更长，避免 3 秒过早断开
        let timeoutSeconds: TimeInterval = (mode == .live) ? 12.0 : 4.0

        finalTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if self.isFinalizing {
                self.log("Final timeout (\(Int(timeoutSeconds))s), force disconnect")
                self.isFinalizing = false
                self.liveState = .idle
                self.liveStartCooldownUntil = Date().addingTimeInterval(0.4)
                self.cleanupSession()
            }
        }
    }

    func cleanupSession(stopPlayback: Bool = true) {
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        liveIdleTask?.cancel()
        liveIdleTask = nil
        livePlaybackTask?.cancel()
        livePlaybackTask = nil
        livePlaybackContext = nil
        liveStreamerSuspendedForPlayback = false
        previewTranslateTask?.cancel()
        previewTranslateTask = nil
        lastPreviewSourceTextByMessage.removeAll()
        previewTranslatedMessageIds.removeAll()

        isLiveActive = false
        isLivePlaybackPaused = false
        streamer.stop()
        if stopPlayback {
            stopCurrentLivePlayback(resetState: false)
        }
        wsClient.disconnect()

        if mode == .live {
            restoreDefaultAudioSessionAfterLive()
        }
        activeSide = nil
        activeMsgId = nil
        isHoldingA = false
        isHoldingB = false
        isHoldingSingle = false
        if mode == .live {
            liveState = .idle
        }
    }

    private func applyPartial(_ text: String) {
        guard !text.isEmpty else { return }

        // 查找或创建活动消息
        if mode == .live || mode == .singleButton {
            return
        }

        if let id = activeMsgId, let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].originalPartial = text
            schedulePreviewTranslation(for: idx)
        } else {
            let msg = ChatMessage(side: .a)
            messages.append(msg)
            activeMsgId = msg.id
            messages[messages.count - 1].originalPartial = text
            schedulePreviewTranslation(for: messages.count - 1)
        }
    }

    private func applyPartialEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              type == "conversation.item.input_audio_transcription.text" else { return }

        if mode == .singleButton {
            applySingleButtonPartialEvent(event)
            return
        }

        guard mode == .live else { return }

        guard let itemId = event["item_id"] as? String else { return }
        let uiSideStr = event["ui_side"] as? String
        let source = event["ui_source_lang"] as? String
        let target = event["ui_target_lang"] as? String
        let text = (event["text"] as? String ?? "") + (event["stash"] as? String ?? "")

        let inferredSide = inferSide(from: text)
        let resolvedSide: Side = uiSideStr.map { $0 == "right" ? .b : .a } ?? inferredSide
        let resolvedLangs: (String, String) = {
            if let source, let target { return (source, target) }
            return resolvedSide == .a ? (langA.id, langB.id) : (langB.id, langA.id)
        }()

        livePendingSideByItemId[itemId] = resolvedSide
        livePendingLangByItemId[itemId] = resolvedLangs

        if lastLivePartialItemId != itemId {
            lastLivePartialItemId = itemId
            let msg = ChatMessage(side: resolvedSide)
            messages.append(msg)
            activeMsgId = msg.id
            livePendingMessageIdByItemId[itemId] = msg.id
        }

        if let id = livePendingMessageIdByItemId[itemId], let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].originalPartial = text
            messages[idx].side = resolvedSide
            messages[idx].sourceLang = resolvedLangs.0
            messages[idx].targetLang = resolvedLangs.1
            if useLocalPreviewTranslation {
                schedulePreviewTranslation(for: idx)
            }
        }

        if liveDebugLogs {
            log("[LivePartial] item=\(itemId.prefix(6)) side=\(uiSideStr ?? (resolvedSide == .b ? "right" : "left")) source=\(source ?? resolvedLangs.0) target=\(target ?? resolvedLangs.1) text=\(text)")
        }
    }

    private func applySingleButtonPartialEvent(_ event: [String: Any]) {
        let itemId = event["item_id"] as? String
        let uiSideStr = event["ui_side"] as? String
        let source = event["ui_source_lang"] as? String
        let target = event["ui_target_lang"] as? String
        let text = (event["text"] as? String ?? "") + (event["stash"] as? String ?? "")
        guard !text.isEmpty else { return }

        let inferredSide = inferSide(from: text)
        let resolvedSide: Side = uiSideStr.map { $0 == "right" ? .b : .a } ?? inferredSide
        let resolvedLangs: (String, String) = {
            if let source, let target { return (source, target) }
            return resolvedSide == .a ? (langA.id, langB.id) : (langB.id, langA.id)
        }()

        if let itemId {
            livePendingSideByItemId[itemId] = resolvedSide
            livePendingLangByItemId[itemId] = resolvedLangs
        }

        let messageId: UUID
        if let itemId, let pendingMsgId = livePendingMessageIdByItemId[itemId] {
            messageId = pendingMsgId
        } else if let id = activeMsgId {
            messageId = id
            if let itemId {
                livePendingMessageIdByItemId[itemId] = id
            }
        } else {
            let msg = ChatMessage(side: resolvedSide)
            messages.append(msg)
            activeMsgId = msg.id
            messageId = msg.id
            if let itemId {
                livePendingMessageIdByItemId[itemId] = msg.id
            }
        }

        activeSide = resolvedSide

        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].side = resolvedSide
            messages[idx].sourceLang = resolvedLangs.0
            messages[idx].targetLang = resolvedLangs.1
            messages[idx].originalPartial = text
        }

        let itemLabel = itemId.map { String($0.prefix(6)) } ?? "-"
        log("[SinglePartial] item=\(itemLabel) side=\(uiSideStr ?? (resolvedSide == .b ? "right" : "left")) source=\(source ?? resolvedLangs.0) target=\(target ?? resolvedLangs.1) text=\(text)")
    }

    private func inferSide(from text: String) -> Side {
        if text.range(of: "\\p{Han}", options: .regularExpression) != nil {
            return .a
        }
        if text.range(of: "[A-Za-z]", options: .regularExpression) != nil {
            return .b
        }
        return .a
    }

    private func applyFinalEvent(_ event: [String: Any]) async {
        let evType = event["type"] as? String ?? ""
        log("ASR Event received: \(evType)")
        
        if evType == "session.finished" {
            log("Session finished by server")
            isFinalizing = false
            if mode == .live {
                liveState = .idle
                liveStartCooldownUntil = Date().addingTimeInterval(0.4)
            }
            cleanupSession()
            return
        }

        // 处理 completed 事件
        if evType == "conversation.item.input_audio_transcription.completed" {
            let itemId = event["item_id"] as? String ?? UUID().uuidString
            guard let transcript = event["transcript"] as? String, !transcript.isEmpty else {
                // 如果是 Live 模式且当前正在 finalize，且没有更多内容，则可以清理了
                if mode == .live && isFinalizing {
                    cleanupSession()
                }
                return
            }

            let pendingSide = livePendingSideByItemId[itemId]
            let pendingLang = livePendingLangByItemId[itemId]
            let pendingMsgId = livePendingMessageIdByItemId[itemId]
            livePendingSideByItemId[itemId] = nil
            livePendingLangByItemId[itemId] = nil
            livePendingMessageIdByItemId[itemId] = nil

            let uiSideStr = event["ui_side"] as? String
            let fallbackSide = pendingSide ?? activeSide ?? .a
            let source = event["ui_source_lang"] as? String ?? pendingLang?.0 ?? (fallbackSide == .a ? langA.id : langB.id)
            let target = event["ui_target_lang"] as? String ?? pendingLang?.1 ?? (fallbackSide == .a ? langB.id : langA.id)
            let side: Side = uiSideStr.map { $0 == "right" ? .b : .a } ?? fallbackSide
            if liveDebugLogs {
                log("[LiveFinal] item=\(itemId.prefix(6)) side=\(uiSideStr ?? (side == .b ? "right" : "left")) source=\(source) target=\(target)")
            }

            let asrMs: Int? = sentenceStartedAtMap[itemId].map { Int(Date().timeIntervalSince($0) * 1000) }
            sentenceStartedAtMap[itemId] = nil

            let asrProvider = event["provider"] as? String ?? asrProviderOverride ?? ProviderRouter.route(
                source: source,
                target: target,
                asrOverride: asrProviderOverride,
                translateOverride: translationProviderOverride,
                ttsOverride: ttsProviderOverride
            ).asrProvider.rawValue
            let asrModel = event["model"] as? String ?? asrModelOverride ?? ProviderRouter.route(
                source: source,
                target: target,
                asrOverride: asrProviderOverride,
                translateOverride: translationProviderOverride,
                ttsOverride: ttsProviderOverride
            ).asrModel

            await processFinalResult(
                transcript: transcript,
                side: side,
                source: source,
                target: target,
                sentenceId: itemId,
                asrMs: asrMs,
                asrProvider: asrProvider,
                asrModel: asrModel
            )

            if mode != .live {
                isFinalizing = false
                cleanupSession(stopPlayback: false)
            } else {
                // Live 模式保持连接，清除当前消息 ID 引用，以便下一句开启新气泡
                activeMsgId = nil
                if isFinalizing {
                    cleanupSession()
                }
            }
        }
    }

    private func processFinalResult(
        transcript: String,
        side: Side,
        source: String,
        target: String,
        sentenceId: String,
        asrMs: Int?,
        asrProvider: String?,
        asrModel: String?
    ) async {
        let pendingMsgId = livePendingMessageIdByItemId[sentenceId]
        // 找到当前正在 partial 的消息并固定它，或者新建
        if let pendingMsgId,
           let idx = messages.firstIndex(where: { $0.id == pendingMsgId }) {
            messages[idx].side = side
            messages[idx].originalFinal = transcript
            messages[idx].originalPartial = ""
            messages[idx].asrProvider = asrProvider
            messages[idx].asrModel = asrModel
            await translateAndOptionallySpeak(index: idx, source: source, target: target, sentenceId: sentenceId, asrMs: asrMs)
        } else if let id = activeMsgId, let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].side = side
            messages[idx].originalFinal = transcript
            messages[idx].originalPartial = ""
            messages[idx].asrProvider = asrProvider
            messages[idx].asrModel = asrModel
            await translateAndOptionallySpeak(index: idx, source: source, target: target, sentenceId: sentenceId, asrMs: asrMs)
        } else {
            let m = ChatMessage(side: side)
            messages.append(m)
            let lastIdx = messages.count - 1
            messages[lastIdx].originalFinal = transcript
            messages[lastIdx].asrProvider = asrProvider
            messages[lastIdx].asrModel = asrModel
            await translateAndOptionallySpeak(index: lastIdx, source: source, target: target, sentenceId: sentenceId, asrMs: asrMs)
        }
    }

    private func translateAndOptionallySpeak(index: Int, source: String, target: String, sentenceId: String, asrMs: Int?) async {
        let text = messages[index].originalFinal ?? ""
        let route = ProviderRouter.route(
            source: source,
            target: target,
            asrOverride: asrProviderOverride,
            translateOverride: translationProviderOverride,
            ttsOverride: ttsProviderOverride
        )

        do {
            let translateStart = Date()
            log("Translating (\(source) -> \(target)) provider=\(route.translationProvider.rawValue) model=\(translationModelOverride ?? "default")...")
            let translated = try await translate(
                text: text,
                source: source,
                target: target,
                provider: route.translationProvider.rawValue,
                model: translationModelOverride
            )
            let translateMs = Int(Date().timeIntervalSince(translateStart) * 1000)
            messages[index].translated = translated
            messages[index].translationProvider = route.translationProvider.rawValue
            messages[index].translationModel = translationModelOverride ?? "provider-default"

            let totalMs = (asrMs ?? 0) + translateMs
            messages[index].asrMs = asrMs
            messages[index].translateMs = translateMs
            messages[index].ttsMs = nil
            messages[index].totalMs = totalMs

            latestMetrics = InteractionMetrics(sentenceId: sentenceId, asrMs: asrMs, translateMs: translateMs, ttsMs: nil, totalMs: totalMs)
            log("[Metrics] sentence=\(sentenceId.prefix(8)) asr=\(asrMs ?? -1)ms trans=\(translateMs)ms total=\(totalMs)ms")

            if autoSpeak, !translated.isEmpty {
                if mode == .live, isLiveActive {
                    startLivePlayback(
                        text: translated,
                        targetLang: target,
                        locale: route.ttsVoiceLocale,
                        provider: route.ttsProvider,
                        messageId: messages[index].id,
                        sentenceId: sentenceId,
                        asrMs: asrMs,
                        translateMs: translateMs,
                        totalBeforeTts: totalMs
                    )
                } else {
                    Task { [weak self] in
                        guard let self else { return }
                        _ = await self.speak(
                            text: translated,
                            targetLang: target,
                            provider: route.ttsProvider,
                            locale: route.ttsVoiceLocale
                        )
                    }
                }
            }
        } catch {
            log("Translate error: \(error)")
            messages[index].translated = NSLocalizedString("translation_failed", comment: "")
            latestMetrics = InteractionMetrics(sentenceId: sentenceId, asrMs: asrMs, translateMs: nil, ttsMs: nil, totalMs: nil)
        }
    }

    private func resolvedTtsModel(for provider: TTSProvider, locale: String) -> String {
        switch provider {
        case .apple:
            return "apple-\(locale)"
        case .qwen:
            return ttsModelOverride?.isEmpty == false ? ttsModelOverride! : "qwen3-tts-flash-realtime"
        }
    }

    private func stopCurrentLivePlayback(resetState: Bool) {
        livePlaybackTask?.cancel()
        livePlaybackTask = nil
        livePlaybackContext = nil
        tts.stopSpeaking(at: .immediate)
        stopQwenStreamPlayback()
        qwenAudioPlayer?.stop()
        qwenAudioPlayer = nil

        if resetState {
            isLivePlaybackPaused = false
            if mode == .live, isLiveActive {
                liveState = .active
                resetLiveIdleTimer()
            }
        }
    }

    private func suspendLiveStreamerForPlayback() {
        guard mode == .live, !liveStreamerSuspendedForPlayback else { return }
        streamer.stop()
        liveStreamerSuspendedForPlayback = true
        log("[Audio][live] listener suspended for playback")
    }

    private func resumeLiveListeningAfterPlayback() -> Bool {
        guard mode == .live, isLiveActive else { return false }
        configureLiveListeningAudioSession()
        guard liveStreamerSuspendedForPlayback else { return true }

        do {
            try streamer.start(preserveCurrentSession: true)
            liveStreamerSuspendedForPlayback = false
            log("[Audio][live] listener resumed after playback")
            return true
        } catch {
            log("[Audio][live] listener resume failed: \(error.localizedDescription)")
            return false
        }
    }

    private func startLivePlayback(
        text: String,
        targetLang: String,
        locale: String,
        provider: TTSProvider,
        messageId: UUID,
        sentenceId: String,
        asrMs: Int?,
        translateMs: Int?,
        totalBeforeTts: Int
    ) {
        guard mode == .live, isLiveActive, !text.isEmpty else { return }

        stopCurrentLivePlayback(resetState: false)
        suspendLiveStreamerForPlayback()
        configureLivePlaybackAudioSession()

        let token = UUID()
        livePlaybackContext = LivePlaybackContext(
            token: token,
            messageId: messageId,
            sentenceId: sentenceId,
            asrMs: asrMs,
            translateMs: translateMs,
            totalBeforeTts: totalBeforeTts,
            ttsProvider: provider.rawValue,
            ttsModel: resolvedTtsModel(for: provider, locale: locale),
            startedAt: Date()
        )
        isLivePlaybackPaused = true
        liveState = .playbackPaused
        liveLastActivityAt = Date()
        log("[LiveFlow] playback_paused provider=\(provider.rawValue)")

        livePlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let actualProvider = await self.speak(text: text, targetLang: targetLang, provider: provider, locale: locale)
            guard !Task.isCancelled else { return }

            if var context = self.livePlaybackContext, context.token == token {
                context.ttsProvider = actualProvider.rawValue
                context.ttsModel = self.resolvedTtsModel(for: actualProvider, locale: locale)
                self.livePlaybackContext = context
            }

            if actualProvider == .qwen {
                self.finishLivePlaybackIfNeeded(token: token)
            } else {
                self.livePlaybackTask = nil
            }
        }
    }

    private func finishLivePlaybackIfNeeded(token: UUID) {
        guard let context = livePlaybackContext, context.token == token else { return }

        let ttsMs = Int(Date().timeIntervalSince(context.startedAt) * 1000)
        if let idx = messages.firstIndex(where: { $0.id == context.messageId }) {
            messages[idx].ttsProvider = context.ttsProvider
            messages[idx].ttsModel = context.ttsModel
            messages[idx].ttsMs = ttsMs
            messages[idx].totalMs = context.totalBeforeTts + ttsMs
        }

        latestMetrics = InteractionMetrics(
            sentenceId: context.sentenceId,
            asrMs: context.asrMs,
            translateMs: context.translateMs,
            ttsMs: ttsMs,
            totalMs: context.totalBeforeTts + ttsMs
        )

        livePlaybackContext = nil
        livePlaybackTask = nil

        if mode == .live, isLiveActive {
            guard resumeLiveListeningAfterPlayback() else {
                isLivePlaybackPaused = false
                liveState = .idle
                cleanupSession(stopPlayback: false)
                return
            }
            isLivePlaybackPaused = false
            liveState = .active
            resetLiveIdleTimer()
            log("[LiveFlow] playback_finished resume_live")
        }
    }

    private func authorizedRealtimeWsURL() async -> URL? {
        guard var c = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else { return nil }

        var items = c.queryItems ?? []
        items.removeAll { $0.name == "token" || $0.name == "guest" }

        if AuthManager.shared.isGuestMode {
            items.append(URLQueryItem(name: "guest", value: "1"))
        } else {
            guard let token = await AuthManager.shared.getIDToken() else { return nil }
            items.append(URLQueryItem(name: "token", value: token))
        }

        c.queryItems = items
        return c.url
    }

    private func schedulePreviewTranslation(for index: Int) {
        guard mode == .live, useGooglePreviewTranslation else { return }
        guard messages.indices.contains(index) else { return }

        let sourceText = messages[index].originalPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText.count >= 8 else { return }

        let msgId = messages[index].id
        if previewTranslatedMessageIds.contains(msgId) { return }
        if lastPreviewSourceTextByMessage[msgId] == sourceText { return }
        lastPreviewSourceTextByMessage[msgId] = sourceText

        let side = messages[index].side
        let sourceLang = side == .a ? langA.id : langB.id
        let targetLang = side == .a ? langB.id : langA.id

        previewTranslateTask?.cancel()
        previewTranslateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            guard messages.indices.contains(index), messages[index].id == msgId else { return }

            let latest = messages[index].originalPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard latest == sourceText else { return }

            if let preview = try? await translate(
                text: sourceText,
                source: sourceLang,
                target: targetLang,
                provider: "google_basic",
                model: nil
            ),
            !preview.isEmpty,
            messages.indices.contains(index),
            messages[index].id == msgId,
            messages[index].originalFinal == nil {
                messages[index].translated = preview
                messages[index].translationProvider = "google_basic_preview"
                messages[index].translationModel = "google-translate-v2-basic"
                previewTranslatedMessageIds.insert(msgId)
            }
        }
    }

    private func translate(text: String, source: String, target: String, provider: String?, model: String?) async throws -> String {
        let endpoint = httpBase.appendingPathComponent("/api/v1/translate/text")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "text": text,
            "source_lang": source,
            "target_lang": target,
            "stream": false
        ]
        if let provider {
            body["provider"] = provider
        }
        if let model, !model.isEmpty {
            body["model"] = model
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "Translate", code: 1)
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["translation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureQwenAudioEngine() throws {
        if !qwenAudioEngineReady {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)
            guard let format else { throw NSError(domain: "TTS", code: 30) }
            qwenAudioEngine.attach(qwenAudioNode)
            qwenAudioEngine.connect(qwenAudioNode, to: qwenAudioEngine.mainMixerNode, format: format)
            qwenAudioEngine.prepare()
            qwenAudioEngineReady = true
        }
        qwenAudioNode.volume = 1.0
        if !qwenAudioEngine.isRunning {
            try qwenAudioEngine.start()
        }
        if !qwenAudioNode.isPlaying {
            qwenAudioNode.play()
        }
    }

    private func stopQwenStreamPlayback() {
        qwenStreamActive = false

        // 防御式停止：避免在节点/引擎状态切换瞬间重复 stop 导致断言
        if qwenAudioNode.engine != nil {
            if qwenAudioNode.isPlaying {
                qwenAudioNode.stop()
            }
            qwenAudioNode.reset()
        }

        if qwenAudioEngine.isRunning {
            qwenAudioEngine.pause()
        }
    }

    private func playQwenPcmChunkBase64(
        _ b64: String,
        callbackType: AVAudioPlayerNodeCompletionCallbackType? = nil,
        completion: (() -> Void)? = nil
    ) throws {
        guard let data = Data(base64Encoded: b64), !data.isEmpty else { return }
        let frameLength = UInt32(data.count / 2)
        guard frameLength > 0 else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw NSError(domain: "TTS", code: 31)
        }

        buffer.frameLength = frameLength
        data.withUnsafeBytes { src in
            guard let dst = buffer.int16ChannelData?[0] else { return }
            dst.assign(from: src.bindMemory(to: Int16.self).baseAddress!, count: Int(frameLength))
        }
        if let callbackType {
            qwenAudioNode.scheduleBuffer(buffer, completionCallbackType: callbackType) { _ in
                completion?()
            }
        } else {
            qwenAudioNode.scheduleBuffer(buffer, completionHandler: nil)
        }
    }

    private func awaitQwenPlaybackDrain() async throws {
        let frameLength: AVAudioFrameCount = 1
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength),
              let channelData = buffer.int16ChannelData else {
            throw NSError(domain: "TTS", code: 34)
        }

        buffer.frameLength = frameLength
        channelData[0][0] = 0

        try await withCheckedThrowingContinuation { continuation in
            qwenAudioNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
        }
    }

    private func streamSpeakWithQwen(text: String, targetLang: String) async throws {
        let endpoint = httpBase.appendingPathComponent("/api/v1/tts")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "provider": "qwen",
            "text": text,
            "lang": targetLang,
            "voice": "Cherry",
            "model": ttsModelOverride?.isEmpty == false ? ttsModelOverride! : "qwen3-tts-flash-realtime",
            "stream": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "TTS", code: 32)
        }

        try ensureQwenAudioEngine()
        qwenAudioNode.volume = 1.0
        qwenStreamActive = true
        defer { qwenStreamActive = false }

        var scheduledAudio = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if !qwenStreamActive { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "audio.delta", let delta = obj["delta"] as? String {
                try playQwenPcmChunkBase64(delta)
                scheduledAudio = true
            } else if type == "done" {
                break
            } else if type == "error" {
                let detail = obj["detail"] as? String ?? "stream_error"
                throw NSError(domain: "TTS", code: 33, userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }

        guard qwenStreamActive, scheduledAudio else { return }
        try await awaitQwenPlaybackDrain()
    }

    private func speak(text: String, targetLang: String, provider: TTSProvider, locale: String) async -> TTSProvider {
        switch provider {
        case .apple:
            qwenAudioPlayer?.stop()
            qwenAudioPlayer = nil
            let u = AVSpeechUtterance(string: text)
            u.rate = 0.5
            u.voice = AVSpeechSynthesisVoice(language: locale)
            tts.speak(u)
            return .apple

        case .qwen:
            do {
                tts.stopSpeaking(at: .immediate)
                qwenAudioPlayer?.stop()
                qwenAudioPlayer = nil
                try await streamSpeakWithQwen(text: text, targetLang: targetLang)
                return .qwen
            } catch {
                log("Qwen TTS stream failed, fallback to Apple TTS: \(error)")
                stopQwenStreamPlayback()
                qwenAudioPlayer?.stop()
                qwenAudioPlayer = nil
                let u = AVSpeechUtterance(string: text)
                u.rate = 0.5
                u.voice = AVSpeechSynthesisVoice(language: locale)
                tts.speak(u)
                return .apple
            }
        }
    }
}

extension ConversationViewModel: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let context = self.livePlaybackContext,
                  context.ttsProvider == TTSProvider.apple.rawValue else { return }
            self.finishLivePlaybackIfNeeded(token: context.token)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.livePlaybackTask = nil
        }
    }
}
