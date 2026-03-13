import SwiftUI
import AVFoundation
import Combine

struct LiveProviderTestView: View {
    @StateObject private var vm: ConversationViewModel = {
        let v = ConversationViewModel()
        v.mode = .live
        return v
    }()

    @State private var showConfig: Bool = false

    @State private var asrProvider: ASRProvider = .qwen
    @State private var showAecTester: Bool = false
    @State private var aecTesterRunning: Bool = false
    @State private var aecSessionMode: AecSessionMode = .aec
    @State private var aecLastMetric: String = ""
    @State private var selectedSampleIndex: Double = 0
    @State private var scrollSampleIndex: Double = 0
    @State private var translateProvider: TranslationProvider = .gemini
    @State private var speechMarkActive: Bool = false
    @State private var speechMarkStartedAt: Date? = nil

    @State private var logRmsSamples: Bool = true
    @State private var rmsThreshold: Double = 0.008
    @State private var minSpeechMs: Double = 120
    @State private var maxSilenceMs: Double = 450
    @State private var duckGain: Double = 0.20
    @State private var ttsProvider: TTSProvider = .qwen

    @State private var asrModel: String = "qwen3-asr-flash-realtime-2026-02-10"
    @State private var translationModel: String = ""
    @State private var ttsModel: String = "qwen3-tts-flash-realtime"

    private let aecSynthesizer = AVSpeechSynthesizer()
    private let aecSynthDelegate = AecSynthDelegate()
    @StateObject private var micMonitor = MicLevelMonitor()

    private let asrModelOptions: [ASRProvider: [String]] = [
        .qwen: ["qwen3-asr-flash-realtime", "qwen3-asr-flash-realtime-2026-02-10"],
        .openai: ["gpt-4o-transcribe"],
        .deepgram: ["nova-3"]
    ]

    private let translateModelOptions: [TranslationProvider: [String]] = [
        .doubao: ["doubao-1.5-lite-32k", "doubao-1.5-pro-32k"],
        .openai: ["gpt-4o-mini", "gpt-4o"],
        .minimax: ["MiniMax-M2.5", "MiniMax-M2.5-highspeed"],
        .gemini: ["gemini-3.1-flash-lite-preview"]
    ]

    private let ttsModelOptions: [TTSProvider: [String]] = [
        .apple: [],
        .qwen: ["qwen3-tts-flash-realtime", "qwen3-tts-vc-realtime-2026-01-15", "qwen3-tts-instruct-flash-realtime"]
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                topBar

                cardSection(title: "Session") {
                    startButton
                    speechMarkButton
                }

                cardSection(title: "Config") {
                    configPanel
                }

                cardSection(title: "Mic Monitor") {
                    micMonitorSection
                }

                cardSection(title: "Messages") {
                    messagesSection
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear {
            vm.autoSpeak = true
            vm.liveRmsThreshold = rmsThreshold
            vm.liveMinSpeechMs = minSpeechMs
            vm.liveMaxSilenceMs = maxSilenceMs
            vm.liveLogRmsSamples = logRmsSamples
            vm.liveDuckGain = duckGain
            micMonitor.logSamples = logRmsSamples
            syncModelsWithProviders()
        }
        .onChange(of: asrProvider) { _, _ in syncAsrModel() }
        .onChange(of: translateProvider) { _, _ in syncTranslationModel() }
        .onChange(of: ttsProvider) { _, _ in syncTtsModel() }
        .onChange(of: logRmsSamples) { _, newValue in
            micMonitor.logSamples = newValue
        }
        .onDisappear { vm.cleanupSession() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Live Provider Test")
                .font(.title2.weight(.semibold))

            Spacer()
        }
    }

    private func cardSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }

    private var configPanel: some View {
        VStack(spacing: 12) {
            providerSelectors
            modelSelectors
            languageSelectors

            HStack {
                Text("Auto TTS")
                Spacer()
                Toggle("", isOn: $vm.autoSpeak).labelsHidden()
            }

            HStack {
                Text("Allow Barge-in")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vm.liveBargeInEnabled },
                    set: { vm.liveBargeInEnabled = $0 }
                ))
                .labelsHidden()
            }

            aecTesterConfigItem

            VStack(alignment: .leading, spacing: 2) {
                Text("Latest Metrics")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Sentence: \(vm.latestMetrics.sentenceId)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("ASR: \(formatMs(vm.latestMetrics.asrMs))  Translate: \(formatMs(vm.latestMetrics.translateMs))  TTS: \(formatMs(vm.latestMetrics.ttsMs))  Total: \(formatMs(vm.latestMetrics.totalMs))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startButton: some View {
        Button {
            vm.asrProviderOverride = asrProvider.rawValue
            vm.translationProviderOverride = translateProvider.rawValue
            vm.ttsProviderOverride = ttsProvider.rawValue
            vm.asrModelOverride = asrModel.isEmpty ? nil : asrModel
            vm.translationModelOverride = translationModel.isEmpty ? nil : translationModel
            vm.ttsModelOverride = ttsModel.isEmpty ? nil : ttsModel
            vm.liveRmsThreshold = rmsThreshold
            vm.liveMinSpeechMs = minSpeechMs
            vm.liveMaxSilenceMs = maxSilenceMs
            vm.liveLogRmsSamples = logRmsSamples
            vm.liveDuckGain = duckGain
            vm.toggleLive()
        } label: {
            Text(vm.isLiveActive ? "Stop Live" : "Start Live")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(vm.isLiveActive ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }

    private var speechMarkButton: some View {
        Button {
            toggleSpeechMark()
        } label: {
            HStack {
                Image(systemName: speechMarkActive ? "mic.fill" : "mic")
                Text(speechMarkActive ? "Stop Speech Mark" : "Start Speech Mark")
                Spacer()
                if let startedAt = speechMarkStartedAt {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    Text(String(format: "%.1fs", elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(speechMarkActive ? Color.orange.opacity(0.18) : Color.gray.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private func toggleSpeechMark() {
        if speechMarkActive {
            let now = Date()
            let startedAt = speechMarkStartedAt ?? now
            let duration = now.timeIntervalSince(startedAt)
            print("[SpeechMark][\(formatTimestamp(now))] stop duration=\(String(format: "%.3f", duration))s")
            speechMarkActive = false
            speechMarkStartedAt = nil
            return
        }

        let now = Date()
        speechMarkActive = true
        speechMarkStartedAt = now
        print("[SpeechMark][\(formatTimestamp(now))] start")
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private var aecTesterConfigItem: some View {
        DisclosureGroup("AEC Tester", isExpanded: $showAecTester) {
            VStack(spacing: 10) {
                Picker("Session", selection: $aecSessionMode) {
                    Text("AEC On").tag(AecSessionMode.aec)
                    Text("AEC Off").tag(AecSessionMode.noAec)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Log RMS")
                    Spacer()
                    Toggle("", isOn: $logRmsSamples)
                        .labelsHidden()
                }

                VStack(spacing: 8) {
                    Text("Tuning Parameters")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    paramRow(title: "RMS Threshold", value: $rmsThreshold, range: 0.001...0.2, step: 0.001)
                    paramRow(title: "Min Speech (ms)", value: $minSpeechMs, range: 50...600, step: 10)
                    paramRow(title: "Max Silence (ms)", value: $maxSilenceMs, range: 50...800, step: 10)
                    paramRow(title: "Duck Gain", value: $duckGain, range: 0.05...1.0, step: 0.05)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(UIColor.tertiarySystemGroupedBackground))
                )

                Button(aecTesterRunning ? "Stop Test" : "Run Test") {
                    if aecTesterRunning {
                        aecTesterRunning = false
                    } else {
                        aecTesterRunning = true
                        Task { @MainActor in
                            await runAecTest()
                        }
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(aecTesterRunning ? Color.orange : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)

                if !aecLastMetric.isEmpty {
                    Text(aecLastMetric)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 6)
        }
    }

    private var micMonitorSection: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mic Level Monitor")
                        .font(.headline)
                    Text("Real RMS over time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Auto Follow", isOn: $micMonitor.autoFollow)
                    .labelsHidden()
                Button(micMonitor.isRunning ? "Stop" : "Start") {
                    if micMonitor.isRunning {
                        micMonitor.stop()
                    } else {
                        micMonitor.start()
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.blue.opacity(0.10))
                )
            }

            MicLevelChart(levels: micMonitor.levels, autoFollow: micMonitor.autoFollow, maxValue: micMonitor.maxValue, avgValue: micMonitor.avgValue, ttsRanges: micMonitor.ttsRanges, selectedIndex: Int(selectedSampleIndex), scrollIndex: Int(scrollSampleIndex), sampleInterval: micMonitor.sampleInterval)
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(UIColor.tertiarySystemGroupedBackground))
                )

            if !micMonitor.levels.isEmpty {
                let maxIndex = Double(max(micMonitor.levels.count - 1, 0))
                VStack(spacing: 8) {
                    if micMonitor.levels.count > 1 {
                        HStack {
                            Text("Scroll")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Slider(value: $scrollSampleIndex, in: 0...maxIndex, step: 1)
                        }

                        HStack {
                            Text("Select")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Slider(value: $selectedSampleIndex, in: 0...maxIndex, step: 1)
                        }
                    } else {
                        Text("Waiting for more samples…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onChange(of: micMonitor.levels.count) { _, newValue in
                    if micMonitor.autoFollow {
                        let latest = Double(max(newValue - 1, 0))
                        selectedSampleIndex = latest
                        scrollSampleIndex = latest
                    }
                }

                if let level = micMonitor.levels[safe: Int(selectedSampleIndex)] {
                    Text(String(format: "Selected: index=%d value=%.6f", Int(selectedSampleIndex), Double(level)))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.messages.isEmpty {
                Text("No messages yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(vm.messages) { m in
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.originalFinal ?? m.originalPartial)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(m.translated ?? "")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ASR: \(m.asrProvider ?? "-") / \(m.asrModel ?? "-")  [\(formatMs(m.asrMs))]")
                        Text("Translate: \(m.translationProvider ?? "-") / \(m.translationModel ?? "-")  [\(formatMs(m.translateMs))]")
                        Text("TTS: \(m.ttsProvider ?? "-") / \(m.ttsModel ?? "-")  [\(formatMs(m.ttsMs))]")
                        Text("Total: \(formatMs(m.totalMs))")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                if m.id != vm.messages.last?.id {
                    Divider()
                }
            }
        }
    }

    private var providerSelectors: some View {
        VStack(spacing: 8) {
            Picker("ASR", selection: $asrProvider) {
                Text("Qwen").tag(ASRProvider.qwen)
                Text("OpenAI").tag(ASRProvider.openai)
                Text("Deepgram").tag(ASRProvider.deepgram)
            }
            .pickerStyle(.segmented)

            Picker("Translate", selection: $translateProvider) {
                Text("Doubao").tag(TranslationProvider.doubao)
                Text("OpenAI").tag(TranslationProvider.openai)
                Text("MiniMax").tag(TranslationProvider.minimax)
                Text("Gemini").tag(TranslationProvider.gemini)
            }
            .pickerStyle(.segmented)

            Picker("TTS", selection: $ttsProvider) {
                Text("Apple").tag(TTSProvider.apple)
                Text("Qwen").tag(TTSProvider.qwen)
            }
            .pickerStyle(.segmented)
        }
    }

    private var modelSelectors: some View {
        VStack(spacing: 8) {
            modelRow(
                title: "ASR Model",
                current: asrModel,
                options: asrModelOptions[asrProvider] ?? [],
                noneLabel: "provider default"
            ) { selected in
                asrModel = selected
            }

            modelRow(
                title: "Translate Model",
                current: translationModel,
                options: translateModelOptions[translateProvider] ?? [],
                noneLabel: "provider default"
            ) { selected in
                translationModel = selected
            }

            if ttsProvider == .apple {
                HStack {
                    Text("TTS Model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("apple-system")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            } else {
                modelRow(
                    title: "TTS Model",
                    current: ttsModel,
                    options: ttsModelOptions[ttsProvider] ?? [],
                    noneLabel: "provider default"
                ) { selected in
                    ttsModel = selected
                }
            }
        }
    }

    private func modelRow(title: String, current: String, options: [String], noneLabel: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Menu(current.isEmpty ? noneLabel : current) {
                Button(noneLabel) { onSelect("") }
                ForEach(options, id: \.self) { model in
                    Button(model) { onSelect(model) }
                }
            }
        }
    }

    private var languageSelectors: some View {
        HStack(spacing: 12) {
            Menu(vm.langA.name) {
                ForEach(supportedLangs) { lang in
                    Button(lang.name) { vm.langA = lang }
                }
            }
            .frame(maxWidth: .infinity)

            Image(systemName: "arrow.left.arrow.right")

            Menu(vm.langB.name) {
                ForEach(supportedLangs) { lang in
                    Button(lang.name) { vm.langB = lang }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func formatMs(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)ms"
    }

    private func syncModelsWithProviders() {
        syncAsrModel()
        syncTranslationModel()
        syncTtsModel()
    }

    private func syncAsrModel() {
        asrModel = asrModelOptions[asrProvider]?.first ?? ""
    }

    private func syncTranslationModel() {
        translationModel = ""
    }

    private func syncTtsModel() {
        if ttsProvider == .apple {
            ttsModel = ""
        } else {
            ttsModel = ttsModelOptions[ttsProvider]?.first ?? ""
        }
    }

    private func paramRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(String(format: "%.3f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Slider(value: value, in: range, step: step)
                .frame(width: 140)
        }
    }

    @MainActor
    private func runAecTest() async {
        let testText = "This is an AEC verification test. Please listen to this sentence and wait."
        let session = AVAudioSession.sharedInstance()

        await MainActor.run {
            aecLastMetric = "Running..."
        }

        if vm.isLiveActive {
            await MainActor.run {
                aecLastMetric = "Stop Live before running AEC test."
                aecTesterRunning = false
            }
            return
        }

        let engine = AVAudioEngine()
        var sampleCount: Double = 0
        var sumSquares: Double = 0
        var tapErrors = 0

        do {
            switch aecSessionMode {
            case .aec:
                try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetooth])
            case .noAec:
                // 仍需打开麦克风，因此保持 playAndRecord，只是不用 voiceChat
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            }
            try? session.setInputGain(1.0)
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)

            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)
            let useFormat: AVAudioFormat? = (inputFormat.sampleRate > 0 && inputFormat.channelCount > 0) ? inputFormat : nil
            input.installTap(onBus: 0, bufferSize: 1024, format: useFormat) { buffer, _ in
                let frames = Int(buffer.frameLength)
                if frames == 0 {
                    tapErrors += 1
                    return
                }
                guard let channel = buffer.floatChannelData?[0] else {
                    tapErrors += 1
                    return
                }
                var localSum: Double = 0
                for i in 0..<frames {
                    let v = Double(channel[i])
                    localSum += v * v
                }
                sumSquares += localSum
                sampleCount += Double(frames)
            }

            try engine.start()
        } catch {
            await MainActor.run {
                aecLastMetric = "AEC test setup failed: \(error.localizedDescription)"
                aecTesterRunning = false
            }
            return
        }

        try? await Task.sleep(nanoseconds: 300_000_000)

        let utterance = AVSpeechUtterance(string: testText)
        utterance.rate = 0.5
        utterance.volume = 1.0
        aecSynthDelegate.bind(monitor: micMonitor)
        aecSynthesizer.delegate = aecSynthDelegate
        aecSynthesizer.stopSpeaking(at: .immediate)
        aecSynthesizer.speak(utterance)


        try? await Task.sleep(nanoseconds: 5_000_000_000)

        await MainActor.run {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        let rms = sampleCount > 0 ? sqrt(sumSquares / sampleCount) : 0
        let modeLabel = (aecSessionMode == .aec) ? "AEC On" : "AEC Off"
        let routeOut = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let routeIn = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        await MainActor.run {
            aecLastMetric = "\(modeLabel) RMS=\(String(format: "%.6f", rms)) taps=\(tapErrors) out=\(routeOut) in=\(routeIn)"
            aecTesterRunning = false
        }
    }
}

private enum AecSessionMode {
    case aec
    case noAec
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

final class AecSynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private var startIndex: Int? = nil
    private weak var monitor: MicLevelMonitor?

    func bind(monitor: MicLevelMonitor) {
        self.monitor = monitor
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let index = monitor?.levels.count
            monitor?.beginTts(at: index)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            monitor?.endTts(at: monitor?.levels.count)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            monitor?.endTts(at: monitor?.levels.count)
        }
    }
}

@MainActor
final class MicLevelMonitor: ObservableObject {
    @Published var levels: [CGFloat] = []
    @Published var isRunning: Bool = false
    @Published var autoFollow: Bool = true
    @Published var ttsRanges: [ClosedRange<Int>] = []
    @Published var sampleInterval: Double = 0
    @Published var logSamples: Bool = false
    @Published var logSamplePrefix: String = "RMS"

    private let engine = AVAudioEngine()
    private let maxSamples: Int = 360
    private var ttsStartIndex: Int? = nil

    var maxValue: CGFloat {
        levels.max() ?? 0
    }

    var avgValue: CGFloat {
        guard !levels.isEmpty else { return 0 }
        return levels.reduce(0, +) / CGFloat(levels.count)
    }

    @MainActor
    func start() {
        guard !isRunning else { return }
        isRunning = true
        levels.removeAll(keepingCapacity: true)
        ttsRanges.removeAll(keepingCapacity: true)
        ttsStartIndex = nil

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleInterval = format.sampleRate > 0 ? (1024.0 / format.sampleRate) : 0

        if engine.isRunning {
            engine.stop()
        }
        input.removeTap(onBus: 0)
        let useFormat: AVAudioFormat? = (format.sampleRate > 0 && format.channelCount > 0) ? format : nil
        input.installTap(onBus: 0, bufferSize: 1024, format: useFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            if frames == 0 { return }
            var sum: Double = 0
            for i in 0..<frames {
                let v = Double(channel[i])
                sum += v * v
            }
            let rms = sqrt(sum / Double(frames))
            DispatchQueue.main.async {
                self.levels.append(CGFloat(rms))
                if self.levels.count > self.maxSamples {
                    self.levels.removeFirst(self.levels.count - self.maxSamples)
                }

                if self.logSamples, self.sampleInterval > 0 {
                    let idx = max(self.levels.count - 1, 0)
                    let time = Double(idx) * self.sampleInterval
                    print(String(format: "[%@] t=%.3f rms=%.6f", self.logSamplePrefix, time, rms))
                }
            }
        }

        do {
            try engine.start()
        } catch {
            isRunning = false
        }
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    @MainActor
    func beginTts(at index: Int?) {
        guard let index else { return }
        ttsStartIndex = index
    }

    @MainActor
    func endTts(at index: Int?) {
        guard let start = ttsStartIndex, let end = index, end >= start else {
            ttsStartIndex = nil
            return
        }
        ttsRanges.append(start...end)
        ttsStartIndex = nil
    }
}

struct MicLevelChart: View {
    let levels: [CGFloat]
    let autoFollow: Bool
    let maxValue: CGFloat
    let avgValue: CGFloat
    let ttsRanges: [ClosedRange<Int>]
    let selectedIndex: Int
    let scrollIndex: Int
    let sampleInterval: Double
    @State private var isSelecting: Bool = false

    private let step: CGFloat = 6
    private let axisWidth: CGFloat = 28
    private let axisHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let plotHeight = geo.size.height - axisHeight
            let contentWidth = max(CGFloat(levels.count) * step, geo.size.width - axisWidth)
            let secondsPerStep = sampleInterval

            HStack(spacing: 0) {
                axisY(height: plotHeight)
                    .frame(width: axisWidth, height: plotHeight)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .bottomLeading) {
                            axisX(width: contentWidth)
                                .frame(width: contentWidth, height: axisHeight)
                                .offset(y: plotHeight)

                            if avgValue > 0 {
                                Path { path in
                                    let y = plotHeight - (avgValue * plotHeight)
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: contentWidth, y: y))
                                }
                                .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            }

                            if maxValue > 0 {
                                Path { path in
                                    let y = plotHeight - (maxValue * plotHeight)
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: contentWidth, y: y))
                                }
                                .stroke(Color.red.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            }

                            ForEach(ttsRanges, id: \ .self) { range in
                                let startX = CGFloat(range.lowerBound) * step
                                let endX = CGFloat(range.upperBound) * step
                                Rectangle()
                                    .fill(Color.purple.opacity(0.12))
                                    .frame(width: max(endX - startX, step), height: plotHeight)
                                    .offset(x: startX)
                            }

                            Path { path in
                                for (idx, level) in levels.enumerated() {
                                    let x = CGFloat(idx) * step
                                    let y = plotHeight - (level * plotHeight)
                                    if idx == 0 {
                                        path.move(to: CGPoint(x: x, y: y))
                                    } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                    }
                                }
                            }
                            .stroke(Color.blue, lineWidth: 2)

                            if levels.indices.contains(selectedIndex) {
                                let x = CGFloat(selectedIndex) * step
                                let y = plotHeight - (levels[selectedIndex] * plotHeight)

                                Path { path in
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: plotHeight))
                                }
                                .stroke(Color.purple.opacity(0.7), lineWidth: 1)

                                Circle()
                                    .fill(Color.purple)
                                    .frame(width: 8, height: 8)
                                    .position(x: x, y: y)

                                Text(String(format: "%.3f", Double(levels[selectedIndex])))
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.black.opacity(0.7))
                                    )
                                    .foregroundColor(.white)
                                    .position(x: min(max(x + 30, 40), contentWidth - 20), y: max(y - 16, 10))
                            }

                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 2, height: plotHeight)
                                .offset(x: max(contentWidth - step, 0))
                                .id("cursor")
                        }
                        .frame(width: contentWidth, height: plotHeight + axisHeight)
                    }
                    .onAppear {
                        guard autoFollow else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo("cursor", anchor: .trailing)
                        }
                    }
                    .onChange(of: levels.count) { _, _ in
                        guard autoFollow else { return }
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("cursor", anchor: .trailing)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private func axisY(height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Path { path in
                path.move(to: CGPoint(x: axisWidth - 1, y: 0))
                path.addLine(to: CGPoint(x: axisWidth - 1, y: height))

                let ticks: [CGFloat] = [0, 0.5, 1.0]
                for tick in ticks {
                    let y = height - (tick * height)
                    path.move(to: CGPoint(x: axisWidth - 6, y: y))
                    path.addLine(to: CGPoint(x: axisWidth - 1, y: y))
                }
            }
            .stroke(Color.secondary, lineWidth: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text("1.0")
                Spacer()
                Text("0.5")
                Spacer()
                Text("0.0")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("max")
                    .foregroundColor(.red)
                Text("avg")
                    .foregroundColor(.orange)
            }
            .font(.caption2)
            .offset(x: 4, y: 2)
        }
    }

    private func axisX(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: width, y: 0))

                let ticks = stride(from: 0, to: width, by: 60)
                for x in ticks {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 6))
                }
            }
            .stroke(Color.secondary, lineWidth: 1)

            let tickIndices = stride(from: 0, to: Int(width), by: 60).map { $0 }
            HStack(spacing: 0) {
                ForEach(tickIndices, id: \ .self) { x in
                    let seconds = (Double(x) / Double(step)) * sampleInterval
                    Text(String(format: "%.1fs", seconds))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .leading)
                }
            }
            .padding(.leading, 2)
            .offset(y: 4)
        }
    }
}
