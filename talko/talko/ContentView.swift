import SwiftUI

struct ContentView: View {
    @StateObject private var vm: ConversationViewModel
    @StateObject private var authManager = AuthManager.shared
    @State private var pickerSide: PickerSide?
    private let onBack: () -> Void

    init(mode: ConversationMode, onBack: @escaping () -> Void) {
        let viewModel = ConversationViewModel()
        viewModel.mode = mode
        _vm = StateObject(wrappedValue: viewModel)
        self.onBack = onBack
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white, AppTheme.pageBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerView

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(vm.messages) { message in
                                MessageBubble(message: message) {
                                    vm.speakMessage(message)
                                }
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: vm.messages.count) { _, _ in scrollToBottom(proxy: proxy) }
                    .onChange(of: vm.messages.last?.originalPartial) { _, _ in scrollToBottom(proxy: proxy) }
                    .onChange(of: vm.messages.last?.translated) { _, _ in scrollToBottom(proxy: proxy) }
                }

                footerView
            }
        }
        .edgesIgnoringSafeArea(.bottom)
        .sheet(item: $pickerSide) { side in
            LanguagePickerSheet(selected: side == .left ? vm.langA : vm.langB, mode: vm.mode) { lang in
                if side == .left { vm.langA = lang } else { vm.langB = lang }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    vm.cleanupSession()
                    onBack()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text(NSLocalizedString("back", comment: ""))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.googleBlue)
                }
                .buttonStyle(.plain)

                Text(titleForMode)
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { vm.autoSpeak.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: vm.autoSpeak ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        Text(NSLocalizedString("auto_speak", comment: ""))
                    }
                    .font(.caption)
                    .foregroundColor(AppTheme.googleBlue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(AppTheme.subtleBlue.opacity(0.7))
                            .overlay(Capsule().stroke(AppTheme.cardBorder, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)

            }
            .padding(.horizontal)

            HStack(spacing: 0) {
                Button { pickerSide = .left } label: {
                    HStack {
                        Text(vm.langA.name)
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

                Button { pickerSide = .right } label: {
                    HStack {
                        Text(vm.langB.name)
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
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(.white.opacity(0.92))
                .shadow(color: AppTheme.googleBlue.opacity(0.06), radius: 8, x: 0, y: 3)
        )
    }

    private var footerView: some View {
        VStack(spacing: 0) {
            switch vm.mode {
            case .dualButton:
                HStack(spacing: 14) {
                    HoldButton(
                        title: vm.langA.holdToTalkText,
                        isHolding: vm.isHoldingA,
                        color: AppTheme.googleBlue.opacity(0.35),
                        activeColor: AppTheme.googleBlue.opacity(0.65)
                    ) { pressing in
                        vm.pressAChanged(pressing)
                    }

                    HoldButton(
                        title: vm.langB.holdToTalkText,
                        isHolding: vm.isHoldingB,
                        color: AppTheme.googleBlue,
                        activeColor: AppTheme.googleBlueDark
                    ) { pressing in
                        vm.pressBChanged(pressing)
                    }
                }
                .padding(.horizontal)

            case .singleButton:
                HoldButton(
                    title: NSLocalizedString("hold_to_talk", comment: ""),
                    isHolding: vm.isHoldingSingle,
                    color: AppTheme.googleBlue,
                    activeColor: AppTheme.googleBlueDark
                ) { pressing in
                    vm.singlePressChanged(pressing)
                }
                .padding(.horizontal)

            case .live:
                Button {
                    vm.toggleLive()
                } label: {
                    HStack(spacing: 10) {
                        if vm.isLiveActive {
                            LiveActiveMiniWave()
                            Image(systemName: "stop.fill")
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(vm.isLiveActive ? NSLocalizedString("live_stop", comment: "") : NSLocalizedString("live_start", comment: ""))
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(vm.isLiveActive ? Color.red.opacity(0.90) : AppTheme.googleBlue)
                    .cornerRadius(27)
                    .shadow(color: (vm.isLiveActive ? Color.red : AppTheme.googleBlue).opacity(0.25), radius: 10, x: 0, y: 6)
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 38)
        .background(
            Rectangle()
                .fill(.white.opacity(0.95))
                .shadow(color: AppTheme.googleBlue.opacity(0.06), radius: 8, x: 0, y: -2)
        )
    }

    private var titleForMode: String {
        switch vm.mode {
        case .dualButton: return NSLocalizedString("mode_dual_title", comment: "")
        case .singleButton: return NSLocalizedString("mode_single_title", comment: "")
        case .live: return NSLocalizedString("mode_live_title", comment: "")
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let last = vm.messages.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

private enum PickerSide: String, Identifiable {
    case left
    case right
    var id: String { rawValue }
}

private struct LiveActiveMiniWave: View {
    private let baseHeights: [CGFloat] = [8, 11, 15, 11, 8]
    private let phases: [Double] = [0.0, 0.9, 1.8, 2.7, 3.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.4) {
                ForEach(0..<5, id: \.self) { idx in
                    let amp = 0.72 + 0.28 * abs(sin((t * 2.3) + phases[idx]))
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(Color.white.opacity(0.96))
                        .frame(width: 2.8, height: max(6, baseHeights[idx] * amp))
                }
            }
            .frame(width: 24, height: 16)
        }
    }
}

struct LanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    let selected: LangOption
    let mode: ConversationMode
    let onSelect: (LangOption) -> Void

    private var filtered: [LangOption] {
        let base: [LangOption]
        if mode == .singleButton || mode == .live {
            base = qwenSupportedLangs
        } else {
            base = supportedLangs
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return base
        }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { lang in
                Button {
                    onSelect(lang)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.name)
                                .foregroundColor(.primary)
                            Text(lang.id.uppercased())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if lang.id == selected.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(AppTheme.googleBlue)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("choose_language", comment: ""))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("done", comment: "")) { dismiss() }
                }
            }
            .searchable(text: $query, prompt: NSLocalizedString("search_language", comment: ""))
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let onPlay: () -> Void

    var body: some View {
        HStack {
            if message.side == .b { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.originalFinal ?? message.originalPartial)
                    .font(.system(size: 13))
                    .opacity(0.72)

                HStack(alignment: .bottom, spacing: 8) {
                    Text(message.translated ?? (message.originalFinal != nil ? "..." : ""))
                        .font(.system(size: 16))

                    if message.translated != nil {
                        Button(action: onPlay) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 14))
                        }
                        .foregroundColor(message.side == .b ? .white : AppTheme.googleBlue)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleColor)
            .foregroundColor(textColor)
            .cornerRadius(18)

            if message.side == .a { Spacer(minLength: 60) }
        }
    }

    private var bubbleColor: Color {
        message.side == .a ? AppTheme.subtleBlue.opacity(0.55) : AppTheme.googleBlue
    }

    private var textColor: Color {
        message.side == .a ? .primary : .white
    }
}

struct HoldButton: View {
    let title: String
    let isHolding: Bool
    let color: Color
    let activeColor: Color
    let onPressingChanged: (Bool) -> Void

    var body: some View {
        Text(isHolding ? NSLocalizedString("listening", comment: "") : title)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(isHolding ? activeColor : color)
            .cornerRadius(27)
            .scaleEffect(isHolding ? 0.965 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHolding)
            .onLongPressGesture(minimumDuration: 0.1, pressing: { pressing in
                onPressingChanged(pressing)
            }, perform: {})
    }
}
