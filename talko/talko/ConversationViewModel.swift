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
final class ConversationViewModel: ObservableObject {
    private let wsURL = AppConfig.wsRealtimeURL
    private let httpBase = AppConfig.httpBaseURL

    @Published var langA: LangOption
    @Published var langB: LangOption

    @Published var autoSpeak: Bool = true
    @Published var isHoldingA = false
    @Published var isHoldingB = false
    @Published var isHoldingSingle = false
    @Published var isLiveActive = false
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
    private var qwenStreamIsDucked = false
    private var liveLocalSpeechActive = false
    private var liveSpeechAccumMs: Double = 0
    private var liveSilenceAccumMs: Double = 0
    private var ttsStartedAt: Date? = nil
    private var ttsStopGuardUntil: Date = .distantPast
    private var ttsPostPlaybackGuardUntil: Date = .distantPast
    private enum LiveBargeState {
        case idle
        case ttsPlaying
        case probe
        case confirmed
    }
    private var liveBargeState: LiveBargeState = .idle
    private var liveBargeSpeechItemId: String? = nil
    private var liveBargeSpeechDetectedAt: Date? = nil
    private var liveBargeProbeChars: Int = 0
    private var liveLastProbeSentAt: Date = .distantPast
    private let liveProbeInterval: TimeInterval = 0.24
    private let liveFallbackProbeInterval: TimeInterval = 1.2
    private let liveBargeConfirmMinChars: Int = 5
    private let liveBargeConfirmMinWindow: TimeInterval = 0.28
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
    var liveBargeInEnabled: Bool = true
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

    // MARK: - Live state machine
    private enum LiveState {
        case idle
        case connecting
        case active
        case stopping
    }
    private var liveState: LiveState = .idle
    private var liveSessionId: UUID = UUID()
    private var liveStartCooldownUntil: Date = .distantPast

    // MARK: - Live idle timeout
    private var liveIdleTask: Task<Void, Never>? = nil
    private var liveLastActivityAt: Date = Date()
    private let liveIdleTimeoutSeconds: TimeInterval = 30

    init() {
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

        setupCallbacks()
    }

    private func configureLiveAudioSessionForAEC() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
            try session.overrideOutputAudioPort(.speaker)
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            log("[AEC][live] enabled category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=\(outputs) inputs=\(inputs)")
        } catch {
            log("[AEC][live] enable failed: \(error.localizedDescription)")
        }
    }

    private func restoreDefaultAudioSessionAfterLive() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            log("[AEC][live] restored category=\(session.category.rawValue) mode=\(session.mode.rawValue) outputs=\(outputs) inputs=\(inputs)")
        } catch {
            log("[AEC][live] restore failed: \(error.localizedDescription)")
        }
    }

    private func setupCallbacks() {
        streamer.onAudioBuffer = { [weak self] base64 in
            guard let self else { return }

            if self.mode == .live {
                let now = Date()
                let qwenPlaying = self.qwenAudioPlayer?.isPlaying ?? false
                let isAnyTtsPlaying = self.tts.isSpeaking || qwenPlaying || self.qwenStreamActive
                if let (rms, durationMs) = self.pcm16RmsAndDurationMs(fromBase64: base64) {
                    self.updateLiveMicGate(rms: rms, durationMs: durationMs)
                }

                if isAnyTtsPlaying {
                    if self.liveBargeState != .ttsPlaying && self.liveBargeState != .probe {
                        self.liveBargeState = .ttsPlaying
                        if liveDebugLogs { self.log("[LiveFlow] state=tts_playing") }
                    }

                    guard self.liveBargeInEnabled else { return }

                    // 播放时默认不上行；仅按固定间隔发 probe 帧探测 speech_started
                    if self.liveBargeState == .ttsPlaying {
                        let interval = self.liveLocalSpeechActive ? self.liveProbeInterval : self.liveFallbackProbeInterval
                        if now.timeIntervalSince(self.liveLastProbeSentAt) >= interval {
                            self.liveLastProbeSentAt = now
                            self.wsClient.sendAudio(base64: base64)
                            if liveDebugLogs {
                                self.log("[LiveFlow] probe_frame_sent active=\(self.liveLocalSpeechActive ? 1 : 0) interval=\(String(format: "%.2f", interval))")
                            }
                        }
                    }

                    // 进入 probe 后允许短窗上行，等待 text 确认
                    if self.liveBargeState == .probe, self.liveLocalSpeechActive {
                        self.wsClient.sendAudio(base64: base64)
                    }
                    return
                }

                // 非播放态：恢复 idle 并走正常上行
                if self.liveBargeState != .idle {
                    self.liveBargeState = .idle
                    self.liveBargeSpeechItemId = nil
                    self.liveBargeSpeechDetectedAt = nil
                    self.liveBargeProbeChars = 0
                    if liveDebugLogs { self.log("[LiveFlow] state=idle") }
                }
                self.restoreQwenStreamVolumeIfNeeded()

                if now < self.ttsStopGuardUntil || now < self.ttsPostPlaybackGuardUntil {
                    return
                }
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

        case .stopping:
            log("Live is stopping, ignore toggle")
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
        let route = ProviderRouter.route(
            source: m.side == .a ? langA.id : langB.id,
            target: target,
            asrOverride: asrProviderOverride,
            translateOverride: translationProviderOverride,
            ttsOverride: ttsProviderOverride
        )

        Task {
            _ = await speak(text: text, targetLang: target, provider: route.ttsProvider, locale: route.ttsVoiceLocale)
        }
    }

    // MARK: - ASR core

    private func start(side: Side) {
        guard activeSide == nil, isFinalizing == false else { return }

        // 单/双按钮使用默认播放会话，不走 live AEC 会话
        restoreDefaultAudioSessionAfterLive()

        activeSide = side
        let msg = ChatMessage(side: side)
        messages.append(msg)
        activeMsgId = msg.id

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
        start(side: .a)
    }

    private func startLive(sessionId: UUID) {
        // live 模式不自动播报
        autoSpeak = false
        // live 模式：不再启用 AEC 特殊会话（保持默认音频路由/音量表现）
        liveLocalSpeechActive = false
        liveSpeechAccumMs = 0
        liveSilenceAccumMs = 0

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
            try streamer.start(preserveCurrentSession: true)
            let session = AVAudioSession.sharedInstance()
            log("[AEC][live] streamer started with category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
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

    private func pcm16RmsAndDurationMs(fromBase64 base64: String) -> (rms: Double, durationMs: Double)? {
        guard let data = Data(base64Encoded: base64), data.count >= 2 else { return nil }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }

        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                let normalized = Double(s) / 32768.0
                sumSquares += normalized * normalized
            }
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        let durationMs = (Double(sampleCount) / 16000.0) * 1000.0
        return (rms, durationMs)
    }

    private func updateLiveMicGate(rms: Double, durationMs: Double) {
        let threshold = max(0.0, liveRmsThreshold)
        let minSpeech = max(0.0, liveMinSpeechMs)
        let maxSilence = max(10.0, liveMaxSilenceMs)

        if rms >= threshold {
            liveSpeechAccumMs += durationMs
            liveSilenceAccumMs = 0
            if liveSpeechAccumMs >= minSpeech {
                liveLocalSpeechActive = true
            }
        } else {
            liveSilenceAccumMs += durationMs
            if liveSilenceAccumMs >= maxSilence {
                liveLocalSpeechActive = false
                liveSpeechAccumMs = 0
            }
        }

        if liveLogRmsSamples {
            log(String(format: "[LiveRMS] rms=%.6f speech=%.0fms silence=%.0fms active=%@ thr=%.3f",
                       rms, liveSpeechAccumMs, liveSilenceAccumMs, liveLocalSpeechActive ? "1" : "0", threshold))
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

        if type == "input_audio_buffer.speech_started",
           let itemId = event["item_id"] as? String {
            sentenceStartedAtMap[itemId] = Date()
            let qwenPlaying = qwenAudioPlayer?.isPlaying ?? false
            let isAnyTtsPlaying = tts.isSpeaking || qwenPlaying || qwenStreamActive
            if isAnyTtsPlaying {
                duckQwenStreamVolumeIfNeeded()
                liveBargeState = .probe
                liveBargeSpeechItemId = itemId
                liveBargeSpeechDetectedAt = Date()
                liveBargeProbeChars = 0
                if liveDebugLogs { log("[LiveFlow] speech_started -> probe") }
            }
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

        if type == "conversation.item.input_audio_transcription.text",
           liveBargeState == .probe,
           let itemId = event["item_id"] as? String,
           itemId == liveBargeSpeechItemId {
            let text = (event["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let stash = (event["stash"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            liveBargeProbeChars += (text + stash).count

            if let detectedAt = liveBargeSpeechDetectedAt,
               Date().timeIntervalSince(detectedAt) >= liveBargeConfirmMinWindow,
               liveBargeProbeChars >= liveBargeConfirmMinChars {
                liveBargeState = .confirmed
                if liveDebugLogs { log("[LiveFlow] barge_confirmed chars=\(liveBargeProbeChars)") }
                tts.stopSpeaking(at: .immediate)
                stopQwenStreamPlayback()
                qwenAudioPlayer?.stop()
                qwenAudioPlayer = nil
                ttsStartedAt = nil
                ttsStopGuardUntil = Date().addingTimeInterval(0.8)
                liveBargeState = .idle
                liveBargeSpeechItemId = nil
                liveBargeSpeechDetectedAt = nil
                liveBargeProbeChars = 0
                if liveDebugLogs { log("[LiveFlow] tts_stopped_by_barge") }
            }
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
        previewTranslateTask?.cancel()
        previewTranslateTask = nil
        lastPreviewSourceTextByMessage.removeAll()
        previewTranslatedMessageIds.removeAll()

        streamer.stop()
        if stopPlayback {
            tts.stopSpeaking(at: .immediate)
            stopQwenStreamPlayback()
            qwenAudioPlayer?.stop()
            qwenAudioPlayer = nil
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
        isLiveActive = false
        liveLocalSpeechActive = false
        liveSpeechAccumMs = 0
        liveSilenceAccumMs = 0
        if mode == .live {
            liveState = .idle
        }
    }

    private func applyPartial(_ text: String) {
        guard !text.isEmpty else { return }

        // 查找或创建活动消息
        if mode == .live {
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
        guard mode == .live else { return }
        guard let type = event["type"] as? String,
              type == "conversation.item.input_audio_transcription.text" else { return }

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
            let source = event["ui_source_lang"] as? String ?? pendingLang?.0 ?? langA.id
            let target = event["ui_target_lang"] as? String ?? pendingLang?.1 ?? langB.id
            let side: Side = uiSideStr.map { $0 == "right" ? .b : .a } ?? pendingSide ?? .a
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

            let ttsMs: Int? = nil

            let totalMs = (asrMs ?? 0) + translateMs
            messages[index].asrMs = asrMs
            messages[index].translateMs = translateMs
            messages[index].ttsMs = nil
            messages[index].totalMs = totalMs

            latestMetrics = InteractionMetrics(sentenceId: sentenceId, asrMs: asrMs, translateMs: translateMs, ttsMs: nil, totalMs: totalMs)
            log("[Metrics] sentence=\(sentenceId.prefix(8)) asr=\(asrMs ?? -1)ms trans=\(translateMs)ms total=\(totalMs)ms")
        } catch {
            log("Translate error: \(error)")
            messages[index].translated = NSLocalizedString("translation_failed", comment: "")
            latestMetrics = InteractionMetrics(sentenceId: sentenceId, asrMs: asrMs, translateMs: nil, ttsMs: nil, totalMs: nil)
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
        qwenAudioNode.volume = qwenStreamIsDucked ? clampedLiveDuckGain() : 1.0
        if !qwenAudioEngine.isRunning {
            try qwenAudioEngine.start()
        }
        if !qwenAudioNode.isPlaying {
            qwenAudioNode.play()
        }
    }

    private func clampedLiveDuckGain() -> Float {
        let clamped = min(max(liveDuckGain, 0.0), 1.0)
        return Float(clamped)
    }

    private func duckQwenStreamVolumeIfNeeded() {
        guard qwenStreamActive || qwenAudioNode.isPlaying else { return }
        qwenAudioNode.volume = clampedLiveDuckGain()
        qwenStreamIsDucked = true
    }

    private func restoreQwenStreamVolumeIfNeeded() {
        guard qwenStreamIsDucked else { return }
        qwenAudioNode.volume = 1.0
        qwenStreamIsDucked = false
    }

    private func stopQwenStreamPlayback() {
        restoreQwenStreamVolumeIfNeeded()
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

    private func playQwenPcmChunkBase64(_ b64: String) throws {
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
        qwenAudioNode.scheduleBuffer(buffer, completionHandler: nil)
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
        qwenStreamIsDucked = false
        qwenAudioNode.volume = 1.0
        qwenStreamActive = true
        ttsStartedAt = Date()
        ttsStopGuardUntil = .distantPast
        ttsPostPlaybackGuardUntil = Date().addingTimeInterval(max(0.9, Double(text.count) * 0.03 + 0.35))
        log("[EchoGuard][live] qwen tts start, postGuardUntil=\(ttsPostPlaybackGuardUntil)")

        for try await line in bytes.lines {
            if !qwenStreamActive { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "audio.delta", let delta = obj["delta"] as? String {
                try playQwenPcmChunkBase64(delta)
            } else if type == "done" {
                break
            } else if type == "error" {
                let detail = obj["detail"] as? String ?? "stream_error"
                throw NSError(domain: "TTS", code: 33, userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }
    }

    private func speak(text: String, targetLang: String, provider: TTSProvider, locale: String) async -> TTSProvider {
        switch provider {
        case .apple:
            qwenAudioPlayer?.stop()
            qwenAudioPlayer = nil
            let u = AVSpeechUtterance(string: text)
            u.rate = 0.5
            u.voice = AVSpeechSynthesisVoice(language: locale)
            ttsStartedAt = Date()
            ttsStopGuardUntil = .distantPast
            ttsPostPlaybackGuardUntil = Date().addingTimeInterval(max(0.9, Double(text.count) * 0.03 + 0.35))
            log("[EchoGuard][live] apple tts start, postGuardUntil=\(ttsPostPlaybackGuardUntil)")
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
                ttsStartedAt = Date()
                ttsStopGuardUntil = .distantPast
                ttsPostPlaybackGuardUntil = Date().addingTimeInterval(max(0.9, Double(text.count) * 0.03 + 0.35))
                tts.speak(u)
                return .apple
            }
        }
    }
}
