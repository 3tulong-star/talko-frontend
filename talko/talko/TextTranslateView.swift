import SwiftUI
import Combine
import AVFoundation

struct TextTranslateView: View {
    @StateObject private var vm = TextTranslateViewModel()
    @FocusState private var isInputFocused: Bool

    private let inputMinHeight: CGFloat = 130
    private let inputHorizontalPadding: CGFloat = 4
    private let inputTopPadding: CGFloat = 6
    private let inputTrailingInset: CGFloat = 34
    private let keyboardAccessoryHeight: CGFloat = 44
    private let outputPlaceholderPadding: CGFloat = 6
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardTop: CGFloat = UIScreen.main.bounds.height
    @State private var outputBottom: CGFloat = 0
    @State private var inputTextHeight: CGFloat = 0
    @State private var inputAvailableWidth: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.white, AppTheme.pageBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        mergedTranslateCard
                            .onChange(of: vm.inputText) { _, newValue in
                                vm.updateFontSizingIfNeeded(text: newValue, measuredHeight: inputTextHeight, minHeight: inputMinHeight)
                            }

                        if !vm.errorText.isEmpty {
                            Text(vm.errorText)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, max(24, keyboardHeight + keyboardAccessoryHeight - max(0, keyboardTop - outputBottom) + 12))
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .contentShape(Rectangle())
            .onTapGesture { isInputFocused = false }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    let screenHeight = UIScreen.main.bounds.height
                    keyboardTop = frame.minY
                    keyboardHeight = max(0, screenHeight - frame.minY)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 10) {
                        if vm.isRecording || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            topCircleButton(
                                icon: vm.isRecording ? "mic.fill" : "mic",
                                tint: vm.isRecording ? .white : AppTheme.googleBlue,
                                bg: vm.isRecording ? .red : AppTheme.subtleBlue
                            ) {
                                if vm.isRecording {
                                    vm.isRecording = false
                                    vm.stopRecording()
                                } else {
                                    vm.isRecording = true
                                    vm.startRecording()
                                }
                            }
                        }

                        topCircleButton(
                            icon: vm.isTranslating ? "hourglass" : "checkmark",
                            tint: .white,
                            bg: vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray.opacity(0.45) : AppTheme.googleBlue
                        ) {
                            guard !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            isInputFocused = false
                            Task { await vm.translateNow() }
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
            .onAppear {
                vm.attachDelegatesIfNeeded()
            }
        }
    }

    private var mergedTranslateCard: some View {
        VStack(spacing: 0) {
            inputSection

            Divider()
                .overlay(AppTheme.cardBorder)
                .overlay(alignment: .center) {
                    swapButton
                }

            outputSection
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                languageMenu(label: vm.sourceLang.name) { lang in
                    vm.sourceLang = lang
                }
                Spacer()
                if !vm.inputText.isEmpty {
                    Button {
                        vm.inputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 2)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.inputText)
                    .focused($isInputFocused)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .font(.system(size: vm.inputFontSize, weight: .semibold))
                    .frame(minHeight: inputMinHeight)
                    .fixedSize(horizontal: false, vertical: true)
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
                            width: max(inputAvailableWidth - 12, 0),
                            fontSize: vm.inputFontSize
                        ) { height in
                            inputTextHeight = height
                            vm.updateFontSizingIfNeeded(text: vm.inputText, measuredHeight: height, minHeight: inputMinHeight)
                        }
                    )

                if vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("输入文本")
                        .font(.system(size: vm.inputFontSize, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, inputTopPadding)
                        .padding(.leading, inputHorizontalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                languageMenu(label: vm.targetLang.name) { lang in
                    vm.targetLang = lang
                }

                Spacer()

                Button {
                    print("[TextTTS] tap speak, text_len=\(vm.translatedText.count)")
                    vm.speakTranslated()
                } label: {
                    HStack(spacing: 4) {
                        if vm.isSpeakingLoading {
                            ProgressView().controlSize(.small)
                        }
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.googleBlue)
                }
                .disabled(vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSpeakingLoading)

                if vm.isSpeaking {
                    Button("停止") { vm.stopSpeaking() }
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            VStack {
                if vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("翻译结果会显示在这里")
                        .font(.system(size: vm.inputFontSize, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, outputPlaceholderPadding)
                        .padding(.leading, inputHorizontalPadding)
                } else {
                    Text(vm.translatedText)
                        .font(.system(size: vm.outputFontSize, weight: .bold))
                        .foregroundStyle(AppTheme.googleBlue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            outputBottom = proxy.frame(in: .global).maxY
                        }
                        .onChange(of: proxy.size.height) { _, _ in
                            outputBottom = proxy.frame(in: .global).maxY
                        }
                }
            )
        }
        .padding(14)
    }

    private var swapButton: some View {
        Button {
            vm.swapLanguages()
        } label: {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppTheme.googleBlue)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.98)))
                .overlay(Circle().stroke(AppTheme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.white.opacity(0.95))
    }

    private func languageMenu(label: String, onPick: @escaping (LangOption) -> Void) -> some View {
        Menu {
            ForEach(supportedLangs) { lang in
                Button(lang.name) { onPick(lang) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(bg))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
final class TextTranslateViewModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var sourceLang: LangOption = supportedLangs.first(where: { $0.id == "en" }) ?? supportedLangs[0]
    @Published var targetLang: LangOption = supportedLangs.first(where: { $0.id == "zh" }) ?? supportedLangs[0]
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

    private let httpBase = AppConfig.httpBaseURL
    private let tts = AVSpeechSynthesizer()
    private var qwenPlayer: AVAudioPlayer?
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
                    if let self {
                        self.updateFontSizingIfNeeded(text: text, measuredHeight: 130, minHeight: 130)
                    }
                }
            }

            textWsClient.onPartialEvent = { [weak self] event in
                Task { @MainActor in
                    guard let type = event["type"] as? String,
                          type == "conversation.item.input_audio_transcription.text" else { return }
                    let text = (event["text"] as? String ?? "") + (event["stash"] as? String ?? "")
                    guard !text.isEmpty else { return }
                    self?.inputText = text
                    if let self {
                        self.updateFontSizingIfNeeded(text: text, measuredHeight: 130, minHeight: 130)
                    }
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
        textStreamer.stop()
        textWsClient.commit()
        textWsClient.finish()
    }

    private func handleTextFinalEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        guard type == "conversation.item.input_audio_transcription.completed" else { return }
        let transcript = event["transcript"] as? String ?? ""
        guard !transcript.isEmpty else { return }
        inputText = transcript
        updateFontSizingIfNeeded(text: transcript, measuredHeight: 130, minHeight: 130)
    }

    private func authorizedRealtimeWsURL() async -> URL? {
        guard var c = URLComponents(url: AppConfig.wsRealtimeURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = c.queryItems ?? []
        items.removeAll { $0.name == "token" || $0.name == "guest" }
        if AuthManager.shared.isGuestMode {
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

        let needsCompact = measuredHeight >= minHeight && !inputIsCompact
        if needsCompact {
            inputIsCompact = true
            inputFontSize = 22
            outputFontSize = 26
        }
    }

    func translateNow() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isTranslating = true
        errorText = ""
        defer { isTranslating = false }

        do {
            let endpoint = httpBase.appendingPathComponent("/api/v1/translate/text")
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

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "TextTranslate", code: 1, userInfo: [NSLocalizedDescriptionKey: body])
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            translatedText = (obj?["translation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            errorText = "Translate failed: \(error.localizedDescription)"
        }
    }

    func speakTranslated() {
        let text = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            print("[TextTTS] skip: empty translated text")
            return
        }
        print("[TextTTS] start request, lang=\(targetLang.id), text_len=\(text.count)")
        isSpeakingLoading = true
        Task {
            configurePlaybackSession()
            await speakWithQwenOrFallback(text)
            await MainActor.run { self.isSpeakingLoading = false }
        }
    }

    func stopSpeaking() {
        tts.stopSpeaking(at: .immediate)
        qwenPlayer?.stop()
        qwenPlayer = nil
        isSpeaking = false
    }

    private func speakWithQwenOrFallback(_ text: String) async {
        do {
            print("[TextTTS] calling /api/v1/tts qwen")
            let endpoint = httpBase.appendingPathComponent("/api/v1/tts")
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "provider": "qwen",
                "text": text,
                "lang": targetLang.id,
                "voice": "Cherry",
                "model": "qwen3-tts-flash-realtime"
            ])

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                print("[TextTTS] invalid response object")
                throw NSError(domain: "TTS", code: 100)
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                print("[TextTTS] non-2xx status=\(http.statusCode) body=\(body)")
                throw NSError(domain: "TTS", code: 1)
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let b64 = (obj?["audioBase64"] as? String) ?? (obj?["audio_base64"] as? String),
                  let audio = Data(base64Encoded: b64) else {
                throw NSError(domain: "TTS", code: 2)
            }

            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            player.prepareToPlay()
            qwenPlayer = player
            await MainActor.run { self.isSpeaking = true }
            let ok = player.play()
            print("[TextTTS] qwen player.play=\(ok), duration=\(player.duration)")
        } catch {
            print("[TextTTS] qwen failed, fallback apple: \(error.localizedDescription)")
            let u = AVSpeechUtterance(string: text)
            u.rate = 0.5
            u.voice = AVSpeechSynthesisVoice(language: targetLang.id == "zh" ? "zh-CN" : "en-US")
            await MainActor.run { self.isSpeaking = true }
            tts.speak(u)
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
