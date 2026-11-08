import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 已确认设计稿的颜色与布局

enum AssistantPalette {
    static let background = Color(red: 0.944, green: 0.962, blue: 0.991)
    static let accent = Color(red: 0.105, green: 0.376, blue: 0.965)
    static let tint = Color(red: 0.845, green: 0.894, blue: 1.000)
    static let line = Color(red: 0.70, green: 0.76, blue: 0.86).opacity(0.52)
    static let surface = Color.white.opacity(0.87)
    // 静态雾蓝光晕置于整窗底层，不参与流式消息的布局。
    static let mist = RadialGradient(colors: [tint.opacity(0.74), background], center: UnitPoint(x: 0.53, y: 0.63), startRadius: 12, endRadius: 460)
}

// 直接从应用资源读取原稿装饰，避免把整页截图当成界面。
enum WelcomeArtwork {
    static let chatPicker = bundledImage("ChatPickerArt")
    static let waves = bundledImage("WelcomeWaves")
    static let topEdge = bundledImage("WelcomeTopEdge")
    static let bottomEdge = bundledImage("WelcomeBottomEdge")
    static let wand = bundledImage("WandMark")
    static let profile = bundledImage("ProfileMark")

    private static func bundledImage(_ name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else {
            return NSImage()
        }
        return image
    }
}

struct ChatView: View {
    @ObservedObject var state: AppState
    let onCompactHeightChange: (CGFloat?) -> Void
    @State private var showSnapshot = false

    var body: some View {
        // 使用窗口实际可用空间布局，小窗与放大后的窗口共享同一份编辑器状态。
        GeometryReader { geometry in
            let compact = geometry.size.width < 600
            content(compact: compact)
                // 来源选择页在原窗口标题栏下展示，底层草稿和聊天布局保留。
                .disabled(state.showChatPicker && !state.isWindowCollapsed)
                .accessibilityHidden(state.showChatPicker && !state.isWindowCollapsed)
                .overlay {
                    if state.showChatPicker && !state.isWindowCollapsed {
                        ChatPickerView(state: state)
                    }
                }
                .sheet(isPresented: $showSnapshot) {
                    if let snapshot = state.snapshot {
                        SnapshotView(snapshot: snapshot)
                            .frame(width: min(720, max(1, geometry.size.width - 32)), height: min(600, max(1, geometry.size.height - 40)))
                    }
                }
                .sheet(item: $state.editingCandidate) { edit in
                    CandidateEditorView(state: state, edit: edit)
                        .frame(width: min(690, max(1, geometry.size.width - 32)), height: min(480, max(1, geometry.size.height - 40)))
                }
        }
        .preferredColorScheme(.light)
        .task {
            await state.bootstrap()
        }
    }

    private func content(compact: Bool) -> some View {
        let collapsed = state.isWindowCollapsed
        return VStack(spacing: 0) {
            // 保留同一份对话滚动视图，收起时只折叠上方区域。
            VStack(spacing: 0) {
                header(compact: compact)
                    .background {
                        if state.messages.isEmpty {
                            Image(nsImage: WelcomeArtwork.topEdge).resizable().interpolation(.high).accessibilityHidden(true)
                        }
                    }
                // 上方区域占用剩余高度；输入栏始终在滚动区域之外，多行输入时向上扩展。
                if state.messages.isEmpty {
                    introduction(compact: compact)
                } else {
                    conversation(compact: compact)
                }
                statusNotice
            }
            .frame(height: collapsed ? 0 : nil)
            .clipped()
            .accessibilityHidden(collapsed)
            .disabled(collapsed)
            .allowsHitTesting(!collapsed)
            ComposerView(state: state, compact: compact)
                .frame(maxWidth: 820)
                .padding(.horizontal, compact ? 14 : 19)
                .padding(.bottom, collapsed ? 6 : (compact ? 12 : 24))
                .padding(.top, collapsed ? 4 : 0)
                .fixedSize(horizontal: false, vertical: collapsed)
                // 用输入栏的实际高度收窗，多行文字、附图和宽度变化都参与测量。
                .onGeometryChange(for: CGFloat?.self) { geometry in
                    collapsed ? ceil(geometry.size.height) : nil
                } action: { height in
                    onCompactHeightChange(height)
                }
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if state.messages.isEmpty {
                Image(nsImage: WelcomeArtwork.bottomEdge).resizable().interpolation(.high).accessibilityHidden(true)
            } else {
                LinearGradient(colors: [Color(red: 0.93, green: 0.93, blue: 0.99), Color(red: 0.82, green: 0.87, blue: 1), Color(red: 0.89, green: 0.91, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .tint(AssistantPalette.accent)
    }

    private func conversation(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(state.messages) { message in
                        MessageView(message: message, state: state)
                            .id(message.id)
                    }
                    if !state.streamingPreview.isEmpty {
                        StreamingPreviewView(preview: state.streamingPreview, isBusy: state.isBusy)
                            .onAppear {
                                state.markPreviewVisible()
                            }
                    }
                    if state.isBusy {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            Text(state.loadingText)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 44)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, compact ? 14 : 32)
                .padding(.vertical, compact ? 16 : 28)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: state.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    // 完整结果从增强版正文开始阅读，长问题列表不遮住首屏复制入口。
                    if let last = state.messages.last, state.isCurrentRefinement(last) {
                        proxy.scrollTo(last.id, anchor: .top)
                    } else {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.isBusy) { _, busy in
                if busy {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            // 只合并滚动请求，正文仍随真实分片立即更新；在下一次 RunLoop 中滚动，避免布局反馈。
            .onReceive(state.$streamingPreview.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)) { preview in
                guard state.isBusy, !preview.isEmpty else { return }
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private func header(compact: Bool) -> some View {
        // 当前来源和下一轮入口同排，标题较长时优先保留操作按钮。
        HStack(spacing: compact ? 9 : 14) {
            sourcePicker
            Spacer(minLength: 0)
            if state.snapshot != nil {
                Button {
                    showSnapshot = true
                } label: {
                    Label("本轮上下文", systemImage: "doc.text.magnifyingglass")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看本轮上下文")
                .help("查看本轮上下文")
            }
            nextRoundButton
                .fixedSize()
        }
        .padding(.horizontal, compact ? 16 : 22)
        .frame(minHeight: compact ? 48 : 54)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.65)).frame(height: 1)
        }
    }

    private var sourcePicker: some View {
        Button {
            state.showChatPicker = true
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                if state.snapshot?.isTrimmed == true {
                    Text("部分早期内容未包含")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(state.selectedChat?.title ?? "选择 Codex 聊天")
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy || state.isConnecting)
        .help("手动选择要参考的 Codex 聊天")
    }

    private var nextRoundButton: some View {
        Button {
            state.resetRound()
        } label: {
            Label("开始下一轮", systemImage: "plus")
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .background(AssistantPalette.accent.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy || state.isConnecting)
        .help("清空本轮问答、草稿及附图，保留来源聊天")
    }

    private func introduction(compact: Bool) -> some View {
        // 插画随可用宽高等比缩放，欢迎文字保持原生排版并独立于底部输入栏。
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = min(width / 450, geometry.size.height / 250, 1.5)
            let artWidth = 450 * scale
            let fade: CGFloat = width > artWidth + 1 ? 0.12 : 0
            ZStack(alignment: .top) {
                Image(nsImage: WelcomeArtwork.waves)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: artWidth, height: 358 * scale)
                    .mask(LinearGradient(stops: [.init(color: fade == 0 ? .white : .clear, location: 0), .init(color: .white, location: fade), .init(color: .white, location: 1 - fade), .init(color: fade == 0 ? .white : .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("接下来想做什么？")
                        .font(.system(size: compact ? 27 : 34, weight: .bold))
                        .tracking(1)
                    Text(state.selectedChat == nil ? "先选择一个来源聊天。" : "写下想法，或直接推荐下一步。")
                        .font(.system(size: compact ? 15 : 18))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 142 * scale)
            }
            .frame(width: width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
    }

    @ViewBuilder
    private var statusNotice: some View {
        if let error = state.errorMessage {
            if state.sideChatFailed && state.retryAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .textSelection(.enabled)
                    HStack {
                        Button("重试侧边聊天", action: state.retry)
                        Button("本轮改用筛选快照", action: state.retryWithSnapshot)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(AssistantPalette.accent)
                    Text(error)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if state.retryAvailable {
                        Button("重试") {
                            state.retry()
                        }
                        .disabled(state.isBusy)
                    } else {
                        Button("重新连接") {
                            state.reconnect()
                        }
                        .disabled(state.isConnecting || state.isBusy)
                    }
                    Button {
                        state.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 10)
            }
        } else if let information = state.information {
            HStack(spacing: 10) {
                Text(information)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.retryAvailable {
                    Button("继续生成") {
                        state.retry()
                    }
                }
                Button {
                    state.information = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 连续消息流中的问题和候选

private struct MessageView: View {
    let message: ChatMessage
    @ObservedObject var state: AppState

    var body: some View {
        content.onAppear {
            state.markResultVisible(message.id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 90)
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.text)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                    ForEach(message.attachments) { attachment in
                        AttachmentChip(attachment: attachment)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
                .background(AssistantPalette.tint, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: 650, alignment: .trailing)
            }
        } else if !message.candidates.isEmpty {
            // 操作仅随正式结果出现，每条候选保留独立的编辑与复制入口。
            VStack(alignment: .leading, spacing: 14) {
                if state.mode == .nextStep {
                    HStack(spacing: 14) {
                        AssistantAvatar()
                        Text("选一条提示词")
                            .font(.custom("Songti SC", size: 25).weight(.bold))
                    }
                }
                ForEach(message.candidates) { candidate in
                    CandidateView(candidate: candidate, state: state)
                }
                if state.isCurrentRefinement(message), !state.remainingQuestions.isEmpty {
                    ClarificationForm(questions: state.remainingQuestions, state: state)
                }
            }
        } else if let question = message.question {
            QuestionView(question: question, number: message.questionNumber ?? 1, state: state)
        } else if !message.text.isEmpty {
            Text(message.text)
                .textSelection(.enabled)
        }
    }
}

// 只呈现从真实 delta 安全解码的正文，不创建可操作的问题或候选，也不显示协议 JSON。
private struct StreamingPreviewView: View {
    let preview: GenerationPreview
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AssistantAvatar()
            VStack(alignment: .leading, spacing: 16) {
                Text(isBusy ? "正在生成 · 完成校验后可操作" : "未完成预览")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !preview.question.isEmpty {
                    Text(preview.question)
                        .font(.system(size: 18, weight: .semibold))
                        .lineSpacing(5)
                }
                ForEach(preview.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 10) {
                        if !candidate.title.isEmpty {
                            Text(candidate.title)
                                .font(.system(size: 16, weight: .semibold))
                        }
                        Text(candidate.prompt)
                            .font(.system(size: 15))
                            .lineSpacing(6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.disabled)
        }
    }
}

// 可只回答部分问题。每个选项保留具体含义，自填内容使用同一份本轮草稿。
private struct ClarificationForm: View {
    let questions: [ClarifyingQuestion]
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("可选澄清问题")
                .font(.headline)
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text)
                        .fontWeight(.semibold)
                    ForEach(question.options) { option in
                        let answer = option.title + "：" + option.detail
                        let selected = state.clarificationDrafts[question.id] == answer
                        Button {
                            state.clarificationDrafts[question.id] = selected ? nil : answer
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    TextField("填写或修改答案", text: Binding(
                        get: { state.clarificationDrafts[question.id] ?? "" },
                        set: { state.clarificationDrafts[question.id] = $0 }
                    ), axis: .vertical)
                        .accessibilityLabel(question.text)
                        .textFieldStyle(.roundedBorder)
                }
                Divider()
            }
            Button("更新增强版提示词", action: state.submit)
                .disabled(!state.canSubmit)
        }
        .disabled(state.isBusy)
    }
}

private struct QuestionView: View {
    let question: ClarifyingQuestion
    let number: Int
    @ObservedObject var state: AppState

    private var isActive: Bool {
        state.activeQuestion?.id == question.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                AssistantAvatar()
                VStack(alignment: .leading, spacing: 7) {
                    Text("第 \(number) 问")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(question.text)
                        .font(.custom("Songti SC", size: 23).weight(.bold))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            VStack(spacing: 0) {
                ForEach(question.options.indices, id: \.self) { index in
                    let option = question.options[index]
                    let selected = isActive && state.draft.hasPrefix("\(index + 1)、\(option.title)")
                    Button {
                        state.chooseOption(option, index: index)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(selected ? AssistantPalette.accent : Color.secondary)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("\(index + 1)、\(option.title)")
                                        .font(.system(size: 15, weight: .medium))
                                    if option.id == question.recommendedID {
                                        Text("推荐")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(AssistantPalette.accent)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(AssistantPalette.tint, in: Capsule())
                                    }
                                }
                                if !option.detail.isEmpty {
                                    Text(option.detail)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? AssistantPalette.tint.opacity(0.48) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isActive || state.isBusy)
                    Divider()
                }
                let otherSelected = isActive && (state.draft.hasPrefix("其他：") || state.draft.hasPrefix("其他:"))
                Button {
                    state.chooseOther()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: otherSelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(otherSelected ? AssistantPalette.accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(question.options.count + 1)、其他")
                                .font(.system(size: 15, weight: .medium))
                            Text("我来补充想法。")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .background(otherSelected ? AssistantPalette.tint.opacity(0.48) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isActive || state.isBusy)
            }
            .background(AssistantPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AssistantPalette.line))
            .opacity(isActive ? 1 : 0.78)
            // 只有当前问题提供结束入口，历史问题仍可回看。
            if isActive {
                Button("结束提问，生成提示词", action: state.finishQuestions)
                    .disabled(state.isBusy || state.isConnecting)
                    .help("按已确认的信息生成候选，同时采用当前输入和附图")
            }
        }
    }
}

private struct CandidateView: View {
    let candidate: PromptCandidate
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(candidate.title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    state.editingCandidate = CandidateEdit(candidate)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(state.isBusy)
                Divider()
                    .frame(height: 14)
                Button {
                    state.copyCandidate(candidate)
                } label: {
                    Label(state.copiedCandidateID == candidate.id ? "已复制" : "复制", systemImage: state.copiedCandidateID == candidate.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(candidate.prompt)
                .font(.system(size: 15))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 操作放在正文下方，窄窗也能保留完整标题与原有编辑、复制按钮。
            Button {
                state.sendCandidate(candidate)
            } label: {
                Label(state.sendingCandidateID == candidate.id ? "发送中…" : "发送到 Codex", systemImage: "paperplane")
            }
            .disabled(state.sendingCandidateID != nil || state.selectedChat == nil)
            .help("覆盖所选 Codex 对话的草稿并发送这条提示词")
            if let notice = state.deliveryNotice, notice.id == candidate.id {
                Text(notice.text)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .background(AssistantPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AssistantPalette.line))
    }
}

private struct AssistantAvatar: View {
    var size: CGFloat = 38

    var body: some View {
        Image("MistPaper")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AttachmentChip: View {
    let attachment: ImageAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let image = NSImage(contentsOf: attachment.fileURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
                    .frame(width: 30, height: 30)
            }
            Text(attachment.name)
                .font(.system(size: 12))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除图片")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AssistantPalette.line, lineWidth: 1))
    }
}

// MARK: - 底部固定的 Codex 式输入栏

private struct ComposerView: View {
    @ObservedObject var state: AppState
    let compact: Bool
    @State private var editorHeight: CGFloat = 54
    @State private var dropTarget = false
    @State private var showAddMenu = false

    var body: some View {
        VStack(spacing: 0) {
            if !state.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(state.pendingAttachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                state.removeImage(attachment.id)
                            }
                            .disabled(state.isBusy)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 13)
            }
            ZStack(alignment: .topLeading) {
                if state.draft.isEmpty {
                    Text(state.composerPlaceholder)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                ComposerEditor(text: $state.draft, enabled: !state.isBusy, onSubmit: state.submit, onPasteImage: state.pasteImage, onDropFile: state.addImage) { height in
                    editorHeight = height
                }
                .frame(height: max(editorHeight, state.messages.isEmpty ? (compact ? 77 : 96) : 54))
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            // 推荐、模型、推理与发送同排；窄窗优先压缩模型标题，保留按钮点击区域。
            HStack(spacing: compact ? 6 : 14) {
                // 使用系统浮层承载菜单，窄窗和收起状态下均可在窗口边缘自动定位。
                Button {
                    showAddMenu.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(showAddMenu ? AssistantPalette.accent : Color.primary)
                        .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                        .background(showAddMenu ? AssistantPalette.tint : .white.opacity(0.78), in: Circle())
                        .overlay(Circle().strokeBorder(AssistantPalette.line))
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
                .accessibilityLabel("添加")
                .help("添加图片或选择聊天上下文 · " + state.contextMode.rawValue)
                .popover(isPresented: $showAddMenu, arrowEdge: .bottom) {
                    ComposerAddMenu(state: state, presented: $showAddMenu)
                }
                // 文字和附图通过发送箭头完善；推荐下一步是单次提交动作。
                if state.messages.isEmpty {
                    Button(action: state.recommendNextStep) {
                        Text("推荐下一步")
                            .font(.system(size: compact ? 13 : 15, weight: .semibold))
                            .padding(.horizontal, compact ? 9 : 17)
                            .padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(AssistantPalette.accent, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isBusy || state.isConnecting || state.selectedChat == nil)
                    .help("结合来源聊天和当前输入，立即推荐下一步")
                } else {
                    Label(state.mode.title, systemImage: state.mode.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                HStack(spacing: compact ? 5 : 24) {
                    Button {
                        state.showModelSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(state.modelLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                    }
                    .frame(maxWidth: compact ? 105 : 140, alignment: .trailing)
                    Divider()
                        .frame(height: 15)
                    Button {
                        state.showModelSettings = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(state.effortLabel)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                    }
                }
                .font(.system(size: compact ? 12 : 15, weight: .medium))
                .buttonStyle(.plain)
                .disabled(state.isBusy || state.isConnecting)
                .popover(isPresented: $state.showModelSettings, arrowEdge: .top) {
                    ModelSettingsView(state: state)
                }
                Button {
                    if state.isBusy {
                        state.cancelGeneration()
                    } else {
                        state.submit()
                    }
                } label: {
                    Image(systemName: state.isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                        .background(state.isBusy || state.canSubmit ? AssistantPalette.accent : Color(red: 0.61, green: 0.62, blue: 1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!state.isBusy && !state.canSubmit)
                .help(state.isBusy ? "停止本次生成" : "提交到提示词助手")
            }
            .padding(.horizontal, compact ? 12 : 19)
            .padding(.vertical, compact ? 10 : 14)
        }
        .background(Color.white.opacity(0.87), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(dropTarget ? AssistantPalette.accent : Color(red: 0.70, green: 0.75, blue: 1), lineWidth: dropTarget ? 2 : 1))
        .shadow(color: AssistantPalette.accent.opacity(0.18), radius: 9, y: 5)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget, perform: acceptDrop)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !state.isBusy else {
            return false
        }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else {
                    url = nil
                }
                if let url {
                    Task { @MainActor in
                        state.addImage(url)
                    }
                }
            }
        }
        return !providers.isEmpty
    }
}

// 三个操作共用图标、文字和勾选列，业务动作仍交给原有状态对象。
private struct ComposerAddMenu: View {
    @ObservedObject var state: AppState
    @Binding var presented: Bool
    @FocusState private var focusedRow: Int?
    @State private var hoveredRow: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(0, title: "添加参考图片…", symbol: "photo.on.rectangle.angled") {
                presented = false
                DispatchQueue.main.async {
                    state.pickImages()
                }
            }
            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 7)
            Text("聊天上下文")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 2)
            ForEach(Array(ContextMode.allCases.enumerated()), id: \.element) { index, mode in
                row(index + 1, title: mode.rawValue, symbol: mode == .snapshot ? "doc.text.magnifyingglass" : "bubble.left.and.bubble.right", selected: mode == state.contextMode) {
                    state.selectContext(mode)
                    presented = false
                }
                .disabled(state.roundContext != nil)
                .opacity(state.roundContext == nil ? 1 : 0.5)
            }
        }
        .padding(7)
        .frame(width: 192)
        .background(LinearGradient(colors: [.white, Color(red: 0.93, green: 0.94, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(AssistantPalette.line.opacity(0.65)))
        .shadow(color: AssistantPalette.accent.opacity(0.10), radius: 3, y: 1)
        .padding(3)
        .preferredColorScheme(.light)
        .disabled(state.isBusy)
        .onAppear {
            focusedRow = 0
        }
        .onExitCommand {
            presented = false
        }
        .onMoveCommand { direction in
            let count = state.roundContext == nil ? 1 + ContextMode.allCases.count : 1
            if direction == .up || direction == .down {
                focusedRow = ((focusedRow ?? 0) + (direction == .up ? count - 1 : 1)) % count
            }
        }
    }

    private func row(_ index: Int, title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(AssistantPalette.accent)
                    .frame(width: 19)
                Text(title)
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AssistantPalette.accent)
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(height: 33)
            .background(AssistantPalette.tint.opacity(hoveredRow == index ? 0.85 : selected ? 0.55 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedRow, equals: index)
        .onKeyPress(.return) {
            action()
            return .handled
        }
        .onHover { inside in
            if inside {
                hoveredRow = index
            } else if hoveredRow == index {
                hoveredRow = nil
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
