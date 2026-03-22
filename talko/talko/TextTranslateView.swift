import SwiftUI
import Combine
import AVFoundation
import UIKit

extension Notification.Name {
    static let textTranslateMicHoldStart = Notification.Name("textTranslateMicHoldStart")
    static let textTranslateMicHoldStop = Notification.Name("textTranslateMicHoldStop")
    static let textTranslateInputStateChanged = Notification.Name("textTranslateInputStateChanged")
}

struct TranslationHistoryItem: Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let sourceLang: String
    let targetLang: String
    var isFavorite: Bool
    let createdAt: Date
}

struct TextTranslateView: View {
    @StateObject private var vm = TextTranslateViewModel()
    @FocusState private var isInputFocused: Bool

    private let inputMinHeight: CGFloat = 130
    private let inputHorizontalPadding: CGFloat = 4
    private let inputTopPadding: CGFloat = 2
    private let inputTrailingInset: CGFloat = 34
    private let inputMeasurementReserve: CGFloat = 32
    @State private var inputTextHeight: CGFloat = 0
    @State private var inputEditorHeight: CGFloat = 130
    @State private var inputAvailableWidth: CGFloat = 0
    @State private var historyItems: [TranslationHistoryItem] = []
    @State private var showHistorySheet: Bool = false
    @State private var pickerSide: PickerSide?
    @State private var showCopiedToast: Bool = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ZStack {
                    LinearGradient(
                        colors: [AppTheme.pageBackground, Color.white],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .top)

                    Circle()
                        .fill(AppTheme.googleBlue.opacity(0.10))
                        .frame(width: 280, height: 280)
                        .blur(radius: 36)
                        .offset(x: -130, y: -290)

                    Circle()
                        .fill(AppTheme.googleBlue.opacity(0.07))
                        .frame(width: 220, height: 220)
                        .blur(radius: 30)
                        .offset(x: 140, y: -180)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            topLanguageBar

                            mergedTranslateCard
                                .frame(minHeight: max(320, proxy.size.height - 110), alignment: .top)

                            if !vm.errorText.isEmpty {
                                Text(vm.errorText)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 2)
                            }

                            if vm.isRecording {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                    Text("录音中…")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isInputFocused = false }
            .overlay(alignment: .top) {
                if showCopiedToast {
                    Text("已复制")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.78))
                        )
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .onAppear {
                vm.attachDelegatesIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .textTranslateMicHoldStart)) { _ in
                vm.lastInputFromASR = true
                vm.startRecording()
            }
            .onReceive(NotificationCenter.default.publisher(for: .textTranslateMicHoldStop)) { _ in
                vm.stopRecording()
            }
            .onAppear {
                let isEmpty = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasTranslation = !vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                NotificationCenter.default.post(
                    name: .textTranslateInputStateChanged,
                    object: (isEmpty, hasTranslation, vm.isRecording)
                )
            }
            .onChange(of: vm.inputText) { _, newValue in
                let isEmpty = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasTranslation = !vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                NotificationCenter.default.post(
                    name: .textTranslateInputStateChanged,
                    object: (isEmpty, hasTranslation, vm.isRecording)
                )
            }
            .onChange(of: vm.translatedText) { _, newValue in
                let isEmpty = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasTranslation = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                NotificationCenter.default.post(
                    name: .textTranslateInputStateChanged,
                    object: (isEmpty, hasTranslation, vm.isRecording)
                )
            }
            .onChange(of: vm.isRecording) { _, isRecording in
                let isEmpty = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasTranslation = !vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                NotificationCenter.default.post(
                    name: .textTranslateInputStateChanged,
                    object: (isEmpty, hasTranslation, isRecording)
                )
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    topCircleButton(
                        icon: "clock.arrow.circlepath",
                        tint: AppTheme.googleBlue,
                        bg: AppTheme.subtleBlue
                    ) {
                        showHistorySheet = true
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    topCircleButton(
                        icon: vm.isTranslating ? "hourglass" : "checkmark",
                        tint: vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray.opacity(0.45) : AppTheme.googleBlue,
                        bg: .clear
                    ) {
                        guard !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        isInputFocused = false
                        Task {
                            await vm.translateNow()
                            if !vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                prependHistoryItem()
                            }
                        }
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isInputFocused = false }
                }
            }
            .navigationTitle("翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showHistorySheet) {
                NavigationStack {
                    historyList
                        .padding(14)
                        .navigationTitle("翻译历史")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(item: $pickerSide) { side in
                LanguagePickerSheet(selected: side == .left ? vm.sourceLang : vm.targetLang, mode: .dualButton) { lang in
                    if side == .left { vm.sourceLang = lang } else { vm.targetLang = lang }
                }
            }
        }
    }

    private var mergedTranslateCard: some View {
        VStack(spacing: 0) {
            inputSection

            if hasTranslation {
                translationDivider
                outputSection
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
    }

    private var hasTranslation: Bool {
        !vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var translationDivider: some View {
        Rectangle()
            .fill(AppTheme.cardBorder)
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    private var inputEditorDynamicHeight: CGFloat {
        let minH = inputMinHeight
        return max(inputEditorHeight, minH)
    }

    private var inputEditorFontSize: CGFloat {
        vm.inputFontSize - 1
    }

    private var measuredInputTextWidth: CGFloat {
        max(inputAvailableWidth - inputTrailingInset - inputMeasurementReserve, 0)
    }

    private var inputInlineActionTopPadding: CGFloat {
        let visibleTextHeight = min(inputTextHeight, inputEditorDynamicHeight - 12)
        let centered = inputTopPadding + max(0, (visibleTextHeight - 32) / 2)
        return min(centered, max(0, inputEditorDynamicHeight - 32))
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                TextEditor(text: $vm.inputText)
                    .focused($isInputFocused)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .font(.system(size: inputEditorFontSize, weight: .semibold))
                    .frame(height: inputEditorDynamicHeight)
                    .padding(.trailing, inputTrailingInset + 4)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    inputAvailableWidth = proxy.size.width
                                }
                                .onChange(of: proxy.size.width) { _, newWidth in
                                    inputAvailableWidth = newWidth
                                }
                        }
                    )
                    .background(
                        TextHeightReader(
                            text: vm.inputText,
                            width: measuredInputTextWidth,
                            fontSize: inputEditorFontSize
                        ) { height in
                            inputTextHeight = height
                            let trimmed = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let wasCompact = vm.inputIsCompact
                            vm.updateFontSizingIfNeeded(text: vm.inputText, measuredHeight: height, minHeight: inputMinHeight)

                            if trimmed.isEmpty {
                                inputEditorHeight = inputMinHeight
                            } else if !wasCompact && vm.inputIsCompact {
                                inputEditorHeight = inputMinHeight
                            } else if vm.inputIsCompact {
                                let targetHeight = max(inputMinHeight, height + 24)
                                if abs(targetHeight - inputEditorHeight) > 0.5 {
                                    inputEditorHeight = targetHeight
                                }
                            } else if abs(inputEditorHeight - inputMinHeight) > 0.5 {
                                inputEditorHeight = inputMinHeight
                            }

                            print("[TextInput][measure] h=\(height) editor=\(inputEditorHeight) width=\(measuredInputTextWidth) font=\(vm.inputFontSize) compact=\(vm.inputIsCompact)")
                        }
                    )
                    .onChange(of: vm.inputText) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            inputEditorHeight = inputMinHeight
                            vm.updateFontSizingIfNeeded(text: "", measuredHeight: 0, minHeight: inputMinHeight)
                        } else {
                            vm.updateFontSizingIfNeeded(text: newValue, measuredHeight: inputTextHeight, minHeight: inputMinHeight)
                        }
                    }

                if vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(vm.isRecording ? "speak now" : "输入文本")
                        .font(.system(size: inputEditorFontSize, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, inputTopPadding + 1)
                        .padding(.leading, inputHorizontalPadding + 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                inputInlineAction
                    .padding(.top, inputInlineActionTopPadding)
                    .padding(.trailing, 2)
            }
        }
        .padding(14)
    }

    private var inputInlineAction: some View {
        Button {
            vm.inputText = ""
            vm.translatedText = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .opacity(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
        .allowsHitTesting(!vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(vm.translatedText)
                .font(.system(size: vm.outputFontSize, weight: .bold))
                .foregroundStyle(AppTheme.googleBlue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

            outputActionBar
        }
        .padding(14)
    }

    private var outputActionBar: some View {
        HStack(spacing: 10) {
            Button {
                print("[TextTTS] tap speak, text_len=\(vm.translatedText.count)")
                vm.speakTranslated()
            } label: {
                HStack(spacing: 6) {
                    if vm.isSpeakingLoading {
                        ProgressView().controlSize(.small)
                    } else if vm.isSpeaking {
                        MiniSpeakerWave()
                    } else {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    Text(vm.isSpeaking ? "播放中" : "播放")
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.googleBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(AppTheme.subtleBlue)
                )
            }
            .buttonStyle(.plain)
            .disabled(vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSpeakingLoading)

            Button {
                UIPasteboard.general.string = vm.translatedText
                withAnimation(.easeOut(duration: 0.2)) {
                    showCopiedToast = true
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    withAnimation(.easeIn(duration: 0.2)) {
                        showCopiedToast = false
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text("复制")
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.googleBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(AppTheme.subtleBlue)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    private var historyList: some View {
        Group {
            if historyItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("暂无历史记录")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(historyItems) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.sourceText)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button {
                                        toggleFavorite(itemId: item.id)
                                    } label: {
                                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                                            .foregroundColor(item.isFavorite ? .yellow : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Text(item.translatedText)
                                    .font(.body)
                                    .foregroundColor(.primary)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(UIColor.tertiarySystemGroupedBackground))
                            )
                        }
                    }
                }
            }
        }
    }

    private var topLanguageBar: some View {
        HStack(spacing: 0) {
            Button {
                pickerSide = .left
            } label: {
                HStack {
                    Text(vm.sourceLang.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .opacity(0.55)
                }
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.plain)

            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    vm.swapLanguages()
                }
            }) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.googleBlue)
                    .padding(10)
                    .background(AppTheme.subtleBlue)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            Button {
                pickerSide = .right
            } label: {
                HStack {
                    Text(vm.targetLang.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .opacity(0.55)
                }
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func prependHistoryItem() {
        let source = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translated.isEmpty else { return }
        let item = TranslationHistoryItem(
            id: UUID(),
            sourceText: source,
            translatedText: translated,
            sourceLang: vm.sourceLang.id,
            targetLang: vm.targetLang.id,
            isFavorite: false,
            createdAt: Date()
        )
        historyItems.insert(item, at: 0)
    }

    private func toggleFavorite(itemId: UUID) {
        guard let idx = historyItems.firstIndex(where: { $0.id == itemId }) else { return }
        historyItems[idx].isFavorite.toggle()
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.white.opacity(0.95))
    }

    private func languageMenu(label: String, minWidth: CGFloat = 0, onPick: @escaping (LangOption) -> Void) -> some View {
        Menu {
            ForEach(supportedLangs) { lang in
                Button(lang.name) { onPick(lang) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(minWidth: minWidth)
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(AppTheme.subtleBlue)
                    .overlay(Capsule().stroke(AppTheme.cardBorder, lineWidth: 1))
            )
        }
    }

    private struct TextHeightReader: View {
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
        let onHeight: (CGFloat) -> Void

        var body: some View {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { onHeight(proxy.size.height) }
                            .onChange(of: proxy.size.height) { _, newValue in
                                onHeight(newValue)
                            }
                    }
                )
                .hidden()
        }
    }

    private func topCircleButton(icon: String, tint: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

}

private enum PickerSide: String, Identifiable {
    case left
    case right
    var id: String { rawValue }
}

private struct MiniSpeakerWave: View {
    private let baseHeights: [CGFloat] = [6, 10, 14, 10, 6]
    private let phases: [Double] = [0.0, 0.9, 1.8, 2.7, 3.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(baseHeights.enumerated()), id: \.offset) { idx, base in
                    let wave = (sin(t * 7.2 + phases[idx]) + 1) / 2
                    let h = max(4, base * (0.55 + 0.9 * wave))

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(AppTheme.googleBlue)
                        .frame(width: 2.5, height: h)
                }
            }
            .frame(height: 16)
        }
    }
}

final class TextTranslateViewModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var sourceLang: LangOption = supportedLangs[0]
    @Published var targetLang: LangOption = supportedLangs[0]
    @Published var inputText: String = ""
    @Published var translatedText: String = ""
    @Published var isTranslating = false
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var isSpeakingLoading = false
    @Published var errorText: String = ""
    @Published var inputFontSize: CGFloat = 28
    @Published var outputFontSize: CGFloat = 32
    @Published var inputIsCompact: Bool = false
    @Published var lastInputFromASR: Bool = false

    private let httpBase = AppConfig.httpBaseURL
    private let tts = AVSpeechSynthesizer()
    private var qwenPlayer: AVAudioPlayer?
    private let qwenAudioEngine = AVAudioEngine()
    private let qwenAudioNode = AVAudioPlayerNode()
    private var qwenAudioEngineReady = false
    private var qwenStreamActive = false
    private var delegatesAttached = false

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            print("[TextTTS] audio route outputs=\(outputs)")
            print("[TextTTS] secondaryAudioShouldBeSilencedHint=\(session.secondaryAudioShouldBeSilencedHint)")
        } catch {
            print("[TextTTS] audio session config failed: \(error.localizedDescription)")
        }
    }

    override init() {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = Locale(identifier: preferred).language.languageCode?.identifier
            ?? Locale(identifier: preferred).languageCode
            ?? "en"
        let normalized = (code == "zh") ? "zh" : code

        let left = supportedLangs.first(where: { $0.id == normalized })
            ?? supportedLangs.first(where: { $0.id == "en" })
            ?? supportedLangs[0]

        let rightDefault = supportedLangs.first(where: { $0.id == "en" }) ?? supportedLangs[0]
        let right = rightDefault.id == left.id
            ? (supportedLangs.first(where: { $0.id != left.id }) ?? rightDefault)
            : rightDefault

        _sourceLang = Published(initialValue: left)
        _targetLang = Published(initialValue: right)

        super.init()
        tts.delegate = self
    }

    func attachDelegatesIfNeeded() {
        guard !delegatesAttached else { return }
        tts.delegate = self
        delegatesAttached = true
    }

    func swapLanguages() {
        let tmp = sourceLang
        sourceLang = targetLang
        targetLang = tmp
    }

    private let textWsClient = RealtimeWSClient()
    private let textStreamer = AudioStreamer()
    private var textSessionActive = false
    private var textAutoStopTask: Task<Void, Never>? = nil
    private var lastTextUpdateAt: Date = .distantPast

    func startRecording() {
        guard !textSessionActive else { return }
        errorText = ""
        textSessionActive = true
        isRecording = true
        print("[TextASR] start recording")

        Task { @MainActor in
            guard let wsURL = await authorizedRealtimeWsURL() else {
                errorText = "Missing Firebase token"
                isRecording = false
                textSessionActive = false
                print("[TextASR] missing token, cannot connect")
                return
            }

            let cfg = RealtimeConfig(
                mode: "single_button",
                leftLang: sourceLang.id,
                rightLang: targetLang.id,
                asrProvider: "qwen",
                asrModel: "qwen3-asr-flash-realtime-2026-02-10"
            )

            textWsClient.onPartialText = { [weak self] text in
                Task { @MainActor in
                    self?.inputText = text
                    self?.markAsrActivity()
                }
            }

            textWsClient.onPartialEvent = { [weak self] event in
                Task { @MainActor in
                    guard let type = event["type"] as? String,
                          type == "conversation.item.input_audio_transcription.text" else { return }
                    let text = (event["text"] as? String ?? "") + (event["stash"] as? String ?? "")
                    guard !text.isEmpty else { return }
                    self?.inputText = text
                    self?.markAsrActivity()
                    print("[TextASR] partial=\(text)")
                }
            }

            textWsClient.onFinalEvent = { [weak self] event in
                Task { @MainActor in
                    self?.handleTextFinalEvent(event)
                }
            }

            textWsClient.connect(url: wsURL, config: cfg)
            print("[TextASR] ws connected")

            do {
                try textStreamer.start()
                textStreamer.onAudioBuffer = { [weak self] base64 in
                    if let self {
                        print("[TextASR] send audio \(base64.count) bytes")
                        self.textWsClient.sendAudio(base64: base64)
                    }
                }
            } catch {
                errorText = "Audio start failed: \(error.localizedDescription)"
                isRecording = false
                textSessionActive = false
                print("[TextASR] audio start failed: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard textSessionActive else { return }
        print("[TextASR] stop recording")
        textSessionActive = false
        isRecording = false
        textAutoStopTask?.cancel()
        textAutoStopTask = nil
        textStreamer.stop()
        textWsClient.commit()
        textWsClient.finish()
    }

    private func markAsrActivity() {
        lastTextUpdateAt = Date()
        // Keep streaming ASR session alive; stop only by explicit user action
        // (mic toggle / keyboard show / page transition).
        textAutoStopTask?.cancel()
        textAutoStopTask = nil
    }

    private func handleTextFinalEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        guard type == "conversation.item.input_audio_transcription.completed" else { return }
        let transcript = event["transcript"] as? String ?? ""
        guard !transcript.isEmpty else { return }
        inputText = transcript
    }

    private func authorizedRealtimeWsURL() async -> URL? {
        guard var c = URLComponents(url: AppConfig.wsRealtimeURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = c.queryItems ?? []
        items.removeAll { $0.name == "token" || $0.name == "guest" }
        if await AuthManager.shared.isGuestMode {
            items.append(URLQueryItem(name: "guest", value: "1"))
        } else if let token = await AuthManager.shared.getIDToken() {
            items.append(URLQueryItem(name: "token", value: token))
        } else {
            return nil
        }
        c.queryItems = items
        return c.url
    }

    func updateFontSizingIfNeeded(text: String, measuredHeight: CGFloat, minHeight: CGFloat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inputIsCompact = false
            inputFontSize = 28
            outputFontSize = 32
            return
        }

        let compactTriggerHeight = max(0, minHeight - 24)
        let needsCompact = measuredHeight >= compactTriggerHeight && !inputIsCompact
        if needsCompact {
            inputIsCompact = true
            inputFontSize = 22
            outputFontSize = 26
        }
    }

    func translateNow() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let startAt = Date()
        isTranslating = true
        errorText = ""
        defer { isTranslating = false }

        do {
            let endpoint = httpBase.appendingPathComponent("/api/v1/translate/text")
            print("[TextTranslate][trace] backend=\(httpBase.absoluteString) endpoint=\(endpoint.absoluteString) provider=gemini stream=false")
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": text,
                "source_lang": sourceLang.id,
                "target_lang": targetLang.id,
                "provider": "gemini",
                "stream": false
            ])

            let requestStartAt = Date()
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let ttfbMs = Int(Date().timeIntervalSince(requestStartAt) * 1000)

            var data = Data()
            for try await chunk in bytes {
                data.append(chunk)
            }
            let downloadDoneAt = Date()
            let downloadMs = Int(downloadDoneAt.timeIntervalSince(requestStartAt) * 1000)

            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[TextTranslate][trace] status=\((resp as? HTTPURLResponse)?.statusCode ?? -1) body_len=\(data.count)")
                throw NSError(domain: "TextTranslate", code: 1, userInfo: [NSLocalizedDescriptionKey: body])
            }

            let providerHeader = http.value(forHTTPHeaderField: "X-Provider") ?? "-"
            let modelHeader = http.value(forHTTPHeaderField: "X-Model") ?? "-"
            print("[TextTranslate][trace] status=\(http.statusCode) backend_provider=\(providerHeader) backend_model=\(modelHeader)")

            let decodeStartAt = Date()
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            translatedText = (obj?["translation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let decodeMs = Int(Date().timeIntervalSince(decodeStartAt) * 1000)

            let totalMs = Int(Date().timeIntervalSince(startAt) * 1000)
            print("[TextTranslate][metric] ttfb_ms=\(ttfbMs) download_ms=\(downloadMs) decode_ms=\(decodeMs) total_ms=\(totalMs) chars=\(text.count)")
        } catch {
            let ms = Int(Date().timeIntervalSince(startAt) * 1000)
            print("[TextTranslate][metric] fail_ms=\(ms)")
            errorText = "Translate failed: \(error.localizedDescription)"
        }
    }

    func speakTranslated() {
        let text = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            print("[TextTTS] skip: empty translated text")
            return
        }
        let tapAt = Date()
        print("[TextTTS] tap, lang=\(targetLang.id), text_len=\(text.count)")
        isSpeakingLoading = true
        Task {
            configurePlaybackSession()
            await speakWithQwenOrFallback(text, tapAt: tapAt)
            await MainActor.run {
                if self.isSpeakingLoading {
                    self.isSpeakingLoading = false
                }
            }
        }
    }

    func stopSpeaking() {
        tts.stopSpeaking(at: .immediate)
        qwenPlayer?.stop()
        qwenPlayer = nil
        stopQwenStreamPlayback()
        isSpeaking = false
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
            guard let dst = buffer.int16ChannelData?[0],
                  let base = src.bindMemory(to: Int16.self).baseAddress else { return }
            dst.assign(from: base, count: Int(frameLength))
        }
        qwenAudioNode.scheduleBuffer(buffer, completionHandler: nil)
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

    private func streamSpeakWithQwen(text: String, tapAt: Date) async throws {
        let endpoint = httpBase.appendingPathComponent("/api/v1/tts")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "qwen",
            "text": text,
            "lang": targetLang.id,
            "voice": "Cherry",
            "model": "qwen3-tts-flash-realtime",
            "stream": true
        ])

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "TTS", code: 32)
        }

        try ensureQwenAudioEngine()
        qwenAudioNode.volume = 1.0
        qwenStreamActive = true
        defer { qwenStreamActive = false }

        var scheduledAudio = false
        var firstChunkAt: Date? = nil
        var firstPlayLogged = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if !qwenStreamActive { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "audio.delta", let delta = obj["delta"] as? String {
                if firstChunkAt == nil {
                    firstChunkAt = Date()
                    let firstChunkMs = Int(firstChunkAt!.timeIntervalSince(tapAt) * 1000)
                    print("[TextTTS][metric] first_chunk_ms=\(firstChunkMs)")
                    Task { @MainActor in
                        self.isSpeakingLoading = false
                    }
                }
                try playQwenPcmChunkBase64(delta)
                scheduledAudio = true
                if !firstPlayLogged {
                    firstPlayLogged = true
                    let firstPlayMs = Int(Date().timeIntervalSince(tapAt) * 1000)
                    print("[TextTTS][metric] first_play_ms=\(firstPlayMs)")
                }
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

    private func speakWithQwenOrFallback(_ text: String, tapAt: Date) async {
        do {
            print("[TextTTS] streaming /api/v1/tts qwen")
            tts.stopSpeaking(at: .immediate)
            qwenPlayer?.stop()
            qwenPlayer = nil
            await MainActor.run { self.isSpeaking = true }
            try await streamSpeakWithQwen(text: text, tapAt: tapAt)
            await MainActor.run {
                self.isSpeaking = false
                self.isSpeakingLoading = false
            }
        } catch {
            print("[TextTTS] qwen stream failed, fallback apple: \(error.localizedDescription)")
            stopQwenStreamPlayback()
            let u = AVSpeechUtterance(string: text)
            u.rate = 0.5
            u.voice = AVSpeechSynthesisVoice(language: targetLang.id == "zh" ? "zh-CN" : "en-US")
            await MainActor.run { self.isSpeaking = true }
            tts.speak(u)
            let fallbackStartMs = Int(Date().timeIntervalSince(tapAt) * 1000)
            print("[TextTTS][metric] fallback_apple_start_ms=\(fallbackStartMs)")
            print("[TextTTS] apple tts speak issued")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.qwenPlayer = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.isSpeaking = false
            self.qwenPlayer = nil
        }
    }
}
