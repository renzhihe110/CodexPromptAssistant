import SwiftUI

// MARK: - 手动选择来源聊天

struct ChatPickerView: View {
    @ObservedObject var state: AppState
    @State private var search = ""

    @State private var pendingID: String?

    var body: some View {
        GeometryReader { geometry in
            let bannerHeight = min(115, max(76, geometry.size.height * 0.16))
            VStack(spacing: 0) {
                header(bannerHeight: bannerHeight)
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("按聊天标题搜索", text: $search)
                                .textFieldStyle(.plain)
                                .onSubmit(searchChats)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 33)
                        .background(AssistantPalette.surface, in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(AssistantPalette.line))
                        Button("搜索", action: searchChats)
                            .buttonStyle(PickerActionStyle(primary: true))
                            .disabled(state.isLoadingChats)
                    }
                    results
                    HStack(spacing: 8) {
                        Button(action: searchChats) {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(state.isLoadingChats)
                        Spacer()
                        if state.isLoadingChats {
                            ProgressView().controlSize(.small)
                        }
                        if state.nextChatCursor != nil {
                            Button("加载更多") {
                                Task {
                                    await state.loadChats(reset: false)
                                }
                            }
                            .disabled(state.isLoadingChats)
                        }
                        Button("确定") {
                            if let selection {
                                state.selectChat(selection)
                            }
                        }
                        .buttonStyle(PickerActionStyle(primary: true))
                        .disabled(selection == nil || state.isLoadingChats)
                    }
                }
                .padding(10)
                .background(.white.opacity(0.40), in: RoundedRectangle(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.white.opacity(0.85)))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.88, blue: 1), AssistantPalette.tint, Color(red: 0.80, green: 0.84, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.85)))
            .padding(7)
            .background(AssistantPalette.tint)
        }
        .buttonStyle(PickerActionStyle())
        .task {
            pendingID = state.selectedChat?.id
            await state.loadChats(reset: true, search: "")
        }
    }

    // 使用参考图中的波浪与聊天插画，标题、取消按钮和搜索区均为原生控件。
    private func header(bannerHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: WelcomeArtwork.chatPicker)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: bannerHeight)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.88), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .accessibilityHidden(true)
            Text("选择 Codex 聊天")
                .font(.system(size: 23, weight: .bold))
            Text("选择本轮提示词需要参考的聊天。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 9)
        .overlay(alignment: .topTrailing) {
            Button("取消") {
                state.showChatPicker = false
            }
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }

    // 选中卡片仅更新待确认的选择，确定时才把可见结果交给原有的来源切换逻辑。
    private var selection: SourceChat? {
        state.chats.first { $0.id == pendingID }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(state.chats) { chat in
                    let selected = pendingID == chat.id
                    Button {
                        pendingID = chat.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(AssistantPalette.accent)
                                .frame(width: 38, height: 38)
                                .background(AssistantPalette.tint.gradient, in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(2)
                                if !chat.cwd.isEmpty {
                                    Text(chat.cwd)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                    Text(chat.updatedAt, style: .relative)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(selected ? AssistantPalette.accent : .gray.opacity(0.60))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: 62)
                        .background(selected ? AssistantPalette.tint.opacity(0.80) : .white.opacity(0.52), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AssistantPalette.accent : .white.opacity(0.88), lineWidth: selected ? 1.6 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if state.chats.isEmpty, !state.isLoadingChats {
                Text(state.errorMessage ?? "暂无匹配的聊天")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
    }

    private func searchChats() {
        Task {
            await state.loadChats(reset: true, search: search)
        }
    }
}

// 搜索与确定共用蓝色主按钮，其余操作使用浅色按钮。
private struct PickerActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, primary ? 16 : 12)
            .frame(height: 31)
            .background((primary ? AssistantPalette.accent : Color.white.opacity(0.75)).gradient, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(primary ? AssistantPalette.accent.opacity(0.7) : AssistantPalette.line))
            .shadow(color: AssistantPalette.accent.opacity(primary ? 0.17 : 0.07), radius: 4, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
    }
}

// 直接展示生成请求使用的不可变来源正文，不重新读取聊天或生成摘要。
struct SnapshotView: View {
    let snapshot: ContextSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本轮上下文")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            Text(snapshot.chat.title)
                .font(.subheadline)
                .lineLimit(2)
            Text("采集于 " + snapshot.capturedAt.formatted(date: .abbreviated, time: .standard) + " · 本轮追问沿用此快照")
                .font(.caption)
                .foregroundStyle(.secondary)
            if snapshot.isTrimmed {
                Text("部分早期轮次未包含。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                Text(verbatim: snapshot.text.isEmpty ? "本轮没有可用的来源正文。" : snapshot.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .background(AssistantPalette.background)
    }
}

// MARK: - 模型与推理强度只覆盖助手任务

struct ModelSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("模型与推理")
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 15) {
                Picker("模型", selection: $state.selectedModelID) {
                    Text("跟随 Codex").tag("")
                    ForEach(state.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                Picker("推理强度", selection: $state.selectedEffort) {
                    Text(state.selectedModelID.isEmpty ? "跟随 Codex" : "模型默认").tag("")
                    ForEach(state.resolvedModel?.efforts ?? []) { effort in
                        Text(effort.title).tag(effort.id)
                    }
                }
                .disabled(state.resolvedModel?.efforts.isEmpty != false)
            }
            .pickerStyle(.menu)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("当前：\(state.modelLabel) · \(state.effortLabel)")
                    .font(.system(size: 12, weight: .medium))
                Text("设置只作用于提示词助手的新生成请求。模型和可选档位来自当前 Codex 目录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("恢复跟随 Codex") {
                state.selectedModelID = ""
                state.selectedEffort = ""
            }
            .font(.system(size: 12))
        }
        .padding(22)
        .frame(width: 335)
        .background(AssistantPalette.background)
        .preferredColorScheme(.light)
        .disabled(state.isBusy)
    }
}

// MARK: - 候选文本的本地编辑

struct CandidateEditorView: View {
    @ObservedObject var state: AppState
    @State private var edit: CandidateEdit

    init(state: AppState, edit: CandidateEdit) {
        self.state = state
        _edit = State(initialValue: edit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑提示词 · \(edit.title)")
                .font(.system(size: 19, weight: .semibold))
            TextEditor(text: $edit.prompt)
                .font(.system(size: 15))
                .padding(8)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AssistantPalette.line))
            HStack {
                Text("保存后可在对话中复制。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    state.editingCandidate = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("保存") {
                    state.saveCandidate(edit)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AssistantPalette.accent)
                .disabled(edit.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AssistantPalette.background)
        .preferredColorScheme(.light)
    }
}
