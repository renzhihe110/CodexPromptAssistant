import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// MARK: - 一个窗口内的问答状态

@MainActor
final class AppState: ObservableObject {
    // 收起仅作用于当前窗口，下一次启动默认展示完整对话。
    @Published var isWindowCollapsed = false
    @Published var draft = ""
    @Published private(set) var mode: AssistantMode = .refine
    @Published private(set) var preferredContext: ContextMode
    @Published private(set) var roundContext: ContextMode?
    @Published private(set) var sideChatFailed = false
    private var roundID = UUID()
    private var forkBoundary: String?

    var contextMode: ContextMode { roundContext ?? preferredContext }

    // 偏好只在新一轮提交前可改；失败回退只覆盖当前轮次。
    func selectContext(_ context: ContextMode) {
        guard !roundStarted, !isBusy else {
            return
        }
        preferredContext = context
        defaults.set(context.rawValue, forKey: "contextMode")
    }

    func retryWithSnapshot() {
        guard sideChatFailed, retryAvailable, !isBusy else {
            return
        }
        roundContext = .snapshot
        if hasCurrentRefinement {
            sideChatFailed = false
        } else {
            performGeneration()
        }
    }

    @Published private(set) var selectedChat: SourceChat?
    @Published private(set) var chats: [SourceChat] = []
    @Published private(set) var nextChatCursor: String?
    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var configuration = EffectiveConfiguration.empty
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var pendingAttachments: [ImageAttachment] = []
    @Published private(set) var snapshot: ContextSnapshot?
    @Published private(set) var activeQuestion: ClarifyingQuestion?
    // 每题可独立选答或填写；点击更新前仍可修改或清空。
    @Published var clarificationDrafts: [String: String] = [:]
    @Published private(set) var questionCount = 0
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingChats = false
    @Published private(set) var isBusy = false
    @Published private(set) var loadingText = ""
    @Published private(set) var streamingPreview = GenerationPreview()
    private(set) var generationTiming: GenerationTiming?
    private var pendingResultMessageID: UUID?
    @Published private(set) var retryAvailable = false
    @Published var errorMessage: String?
    @Published var information: String?
    @Published var showChatPicker = false
    @Published var showModelSettings = false
    @Published var editingCandidate: CandidateEdit?
    @Published var copiedCandidateID: String?

    // 单次只提交一条候选，反馈归属具体卡片，不复用生成失败的重试入口。
    @Published private(set) var sendingCandidateID: String?
    @Published private(set) var deliveryNotice: (id: String, text: String)?
    private var deliveryTask: Task<Void, Never>?

    @Published var selectedModelID: String {
        didSet {
            guard oldValue != selectedModelID else {
                return
            }
            defaults.set(selectedModelID, forKey: "modelOverride")
            normalizeEffort()
        }
    }

    @Published var selectedEffort: String {
        didSet {
            defaults.set(selectedEffort, forKey: "effortOverride")
        }
    }

    private let defaults: UserDefaults
    private let reader = CodexReader()
    private let engine = PromptEngine()
    private let attachments = AttachmentStore()
    private var generationTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var generationID = UUID()
    private var roundStarted = false
    // 手动结束或自动产出候选后，后续重试和补充都只生成候选。
    private var candidatesOnly = false
    private var initialDraft = ""
    private var answers: [AnswerRecord] = []
    private var feedback: [String] = []
    private var roundAttachments: [ImageAttachment] = []
    private var latestCandidates: [PromptCandidate] = []
    private var chatSearch = ""
    private var didBootstrap = false

    // 仅保存离开来源时的本轮数据；请求、窗口和模型设置不随来源切换。
    private struct RoundProgress {
        var id = UUID()
        var context: ContextMode?
        var forkBoundary: String?
        var sideChatFailed = false
        var mode: AssistantMode = .refine
        var draft = ""
        var messages: [ChatMessage] = []
        var pendingAttachments: [ImageAttachment] = []
        var snapshot: ContextSnapshot?
        var activeQuestion: ClarifyingQuestion?
        var clarificationDrafts: [String: String] = [:]
        var questionCount = 0
        var roundStarted = false
        var candidatesOnly = false
        var initialDraft = ""
        var answers: [AnswerRecord] = []
        var feedback: [String] = []
        var roundAttachments: [ImageAttachment] = []
        var latestCandidates: [PromptCandidate] = []
        var preview = GenerationPreview()
        var retryAvailable = false
        var errorMessage: String?
        var information: String?
        var deliveryNotice: (id: String, text: String)?
    }

    private var savedRounds: [String: RoundProgress] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferredContext = defaults.string(forKey: "contextMode").flatMap(ContextMode.init(rawValue:)) ?? .snapshot
        self.selectedModelID = defaults.string(forKey: "modelOverride") ?? ""
        self.selectedEffort = defaults.string(forKey: "effortOverride") ?? ""
    }

    var resolvedModelID: String? {
        if !selectedModelID.isEmpty {
            return selectedModelID
        }
        return configuration.model ?? models.first(where: \.isDefault)?.id ?? models.first?.id
    }

    var resolvedModel: ModelOption? {
        models.first { $0.id == resolvedModelID }
    }

    var resolvedEffort: String? {
        if !selectedEffort.isEmpty {
            return selectedEffort
        }
        let inherited = selectedModelID.isEmpty ? configuration.effort : nil
        if let inherited, resolvedModel?.efforts.contains(where: { $0.id == inherited }) != false {
            return inherited
        }
        return resolvedModel?.defaultEffort
    }

    var modelLabel: String {
        resolvedModel?.name ?? resolvedModelID ?? "跟随 Codex"
    }

    var effortLabel: String {
        guard let resolvedEffort else {
            return "默认"
        }
        return ReasoningOption(id: resolvedEffort, detail: "").title
    }

    var hasCurrentRefinement: Bool { mode == .refine && !latestCandidates.isEmpty }

    private var currentResult: ChatMessage? {
        messages.last { !$0.candidates.isEmpty }
    }

    var remainingQuestions: [ClarifyingQuestion] { currentResult?.clarificationQuestions ?? [] }

    // 当前正式版本是复制和更新的共同底稿；只有存在待处理改动才需要请求模型。
    var canUpdateRefinement: Bool {
        guard hasCurrentRefinement, !isBusy, !isConnecting, selectedChat != nil else { return false }
        return currentResult?.generatedPrompt != latestCandidates.first?.prompt ||
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty ||
            clarificationDrafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func updateRefinement() {
        guard canUpdateRefinement else { return }
        let records = remainingQuestions.compactMap { question -> AnswerRecord? in
            guard let answer = clarificationDrafts[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty else { return nil }
            return AnswerRecord(questionID: question.id, question: question.text, answer: answer)
        }
        isWindowCollapsed = false
        performGeneration(update: RefinementUpdate(answers: records, note: draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: pendingAttachments))
    }

    func isCurrentRefinement(_ message: ChatMessage) -> Bool {
        mode == .refine && message.candidates.first?.id == latestCandidates.first?.id && !message.candidates.isEmpty
    }

    var canSubmit: Bool {
        guard !hasCurrentRefinement, !isBusy, !isConnecting, selectedChat != nil else {
            return false
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "其他：" || text == "其他:" {
            return false
        }
        return !text.isEmpty || (!roundStarted && (mode == .nextStep || !pendingAttachments.isEmpty))
    }

    var composerPlaceholder: String {
        if selectedChat == nil {
            return "先选择一个 Codex 聊天…"
        }
        if activeQuestion != nil {
            return "选择一个选项，或补充你的想法…"
        }
        if !latestCandidates.isEmpty {
            return mode == .refine ? "补充要求，更新增强版提示词…" : "可以补充要求，继续调整候选提示词…"
        }
        return "写下你想完善的提示词…"
    }

    // 启动只读取配置；历史快照等到用户真正提交时获取。
    func bootstrap() async {
        guard !didBootstrap, !isConnecting else {
            return
        }
        isConnecting = true
        defer {
            isConnecting = false
        }
        do {
            configuration = try await reader.configuration()
            models = try await reader.models()
            if !selectedModelID.isEmpty, !models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = ""
                information = "上次所选模型不在当前目录中，已恢复跟随 Codex。"
            }
            normalizeEffort()
            if let id = defaults.string(forKey: "lastChatID") {
                selectedChat = try await reader.chat(id: id)
            }
            didBootstrap = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reconnect() {
        guard !isConnecting, !isBusy else {
            return
        }
        didBootstrap = false
        errorMessage = nil
        isConnecting = true
        Task {
            do {
                try await reader.reconnect()
                isConnecting = false
                await bootstrap()
            } catch {
                isConnecting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadChats(reset: Bool, search: String? = nil) async {
        guard !isLoadingChats else {
            return
        }
        if let search {
            chatSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        isLoadingChats = true
        defer {
            isLoadingChats = false
        }
        do {
            let page = try await reader.listChats(cursor: reset ? nil : nextChatCursor, search: chatSearch)
            if reset {
                chats = page.chats
            } else {
                let existing = Set(chats.map(\.id))
                chats.append(contentsOf: page.chats.filter { !existing.contains($0.id) })
            }
            nextChatCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectChat(_ chat: SourceChat) {
        guard !isBusy else {
            return
        }
        if let previousID = selectedChat?.id, previousID != chat.id {
            savedRounds[previousID] = RoundProgress(id: roundID, context: roundContext, forkBoundary: forkBoundary, sideChatFailed: sideChatFailed, mode: mode, draft: draft, messages: messages, pendingAttachments: pendingAttachments, snapshot: snapshot, activeQuestion: activeQuestion, clarificationDrafts: clarificationDrafts, questionCount: questionCount, roundStarted: roundStarted, candidatesOnly: candidatesOnly, initialDraft: initialDraft, answers: answers, feedback: feedback, roundAttachments: roundAttachments, latestCandidates: latestCandidates, preview: streamingPreview, retryAvailable: retryAvailable, errorMessage: errorMessage, information: information, deliveryNotice: deliveryNotice)
            restoreRound(savedRounds.removeValue(forKey: chat.id) ?? RoundProgress())
        }
        selectedChat = chat
        defaults.set(chat.id, forKey: "lastChatID")
        showChatPicker = false
        configurationTask?.cancel()
        configurationTask = Task {
            do {
                let result = try await reader.configuration(cwd: chat.cwd)
                guard !Task.isCancelled, selectedChat?.id == chat.id else {
                    return
                }
                configuration = result
                normalizeEffort()
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // 推荐入口直接提交草稿和附图；进行中的一轮只能通过原有回答或重试入口继续。
    func recommendNextStep() {
        guard !isBusy, !isConnecting, !roundStarted, selectedChat != nil else {
            return
        }
        mode = .nextStep
        guard canSubmit else {
            mode = .refine
            information = "请先补全输入内容，再推荐下一步。"
            return
        }
        submit()
    }

    func resetRound() {
        // 只有显式开始下一轮才删除当前来源的附图，切换来源只转移文件引用。
        let oldID = roundID
        Task {
            await engine.releaseRound(oldID)
        }
        attachments.remove(roundAttachments + pendingAttachments)
        restoreRound(RoundProgress())
    }

    private func restoreRound(_ round: RoundProgress) {
        cancelGeneration()
        deliveryTask?.cancel()
        sendingCandidateID = nil
        copiedCandidateID = nil
        editingCandidate = nil
        generationTiming = nil
        pendingResultMessageID = nil
        roundID = round.id
        roundContext = round.context
        forkBoundary = round.forkBoundary
        sideChatFailed = round.sideChatFailed
        mode = round.mode
        draft = round.draft
        messages = round.messages
        pendingAttachments = round.pendingAttachments
        snapshot = round.snapshot
        activeQuestion = round.activeQuestion
        clarificationDrafts = round.clarificationDrafts
        questionCount = round.questionCount
        roundStarted = round.roundStarted
        candidatesOnly = round.candidatesOnly
        initialDraft = round.initialDraft
        answers = round.answers
        feedback = round.feedback
        roundAttachments = round.roundAttachments
        latestCandidates = round.latestCandidates
        streamingPreview = round.preview
        retryAvailable = round.retryAvailable
        errorMessage = round.errorMessage
        information = round.information
        deliveryNotice = round.deliveryNotice
    }

    func chooseOption(_ option: QuestionOption, index: Int) {
        guard !isBusy else {
            return
        }
        draft = "\(index + 1)、\(option.title)"
    }

    func chooseOther() {
        guard !isBusy else {
            return
        }
        draft = "其他："
    }

    func submit() {
        guard canSubmit else {
            return
        }
        submit(endingQuestions: false)
    }

    // 结束入口只处理当前待答问题，可以跳过，也可以连同当前草稿和附图一起提交。
    func finishQuestions() {
        guard activeQuestion != nil, !isBusy, !isConnecting, selectedChat != nil else {
            return
        }
        submit(endingQuestions: true)
    }

    private func submit(endingQuestions: Bool) {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 数字菜单在提交边界展开含义，“其他”先等待补充，不消耗一次回答。
        if endingQuestions, let question = activeQuestion, ["其他：", "其他:", String(question.options.count + 1)].contains(text) {
            text = ""
        }
        if let question = activeQuestion, let number = Int(text) {
            if number == question.options.count + 1 {
                chooseOther()
                information = "请补充你的具体想法，再提交回答。"
                return
            }
            guard (1...question.options.count).contains(number) else {
                information = "请选择 1～\(question.options.count + 1)，或输入文字说明。"
                return
            }
            text = "\(number)、\(question.options[number - 1].title)"
        }
        let addedImages = pendingAttachments
        pendingAttachments.removeAll()
        roundAttachments.append(contentsOf: addedImages)
        if !roundStarted {
            roundContext = preferredContext
            initialDraft = text
            roundStarted = true
        } else if let question = activeQuestion {
            if !text.isEmpty {
                answers.append(AnswerRecord(question: question.text, answer: text))
            }
            activeQuestion = nil
        } else if !text.isEmpty {
            feedback.append(text)
        }
        if endingQuestions {
            candidatesOnly = true
        }
        let visible = text.nonEmpty(or: endingQuestions ? "结束提问，生成提示词。" : "结合当前聊天，帮我推荐下一步。")
        messages.append(ChatMessage(role: .user, text: visible, attachments: addedImages))
        // 只在提交通过校验后展开；换行、无效选项和停止生成不会触发展开。
        isWindowCollapsed = false
        draft = ""
        performGeneration()
    }

    func retry() {
        guard !hasCurrentRefinement, retryAvailable, !isBusy, roundStarted else {
            return
        }
        performGeneration()
    }

    func cancelGeneration() {
        generationID = UUID()
        generationTask?.cancel()
        if isBusy {
            generationTiming?.outcome = "cancelled"
            information = "已停止生成，当前问答已保留。"
            retryAvailable = roundStarted
        }
        isBusy = false
    }

    // 每次请求都捕获独立身份，来源切换或取消后不会接收旧任务结果。
    private func performGeneration(update: RefinementUpdate? = nil) {
        guard let chat = selectedChat, !isBusy else {
            return
        }
        let id = UUID()
        generationID = id
        generationTiming = GenerationTiming(id: id, startedAt: Date())
        pendingResultMessageID = nil
        streamingPreview = GenerationPreview()
        isBusy = true
        retryAvailable = false
        errorMessage = nil
        information = nil
        sideChatFailed = false
        loadingText = contextMode == .sideChat ? "正在准备侧边聊天…" : snapshot == nil ? "正在读取所选聊天…" : "正在整理下一步…"
        let previousTask = generationTask
        generationTask = Task {
            // 等待被取消的请求退出后再使用同一分支，避免立即重试抢在中断之前。
            await previousTask?.value
            guard generationID == id, !Task.isCancelled else {
                return
            }
            do {
                if contextMode == .sideChat, forkBoundary == nil {
                    do {
                        let boundary = try await reader.forkBoundary(for: chat)
                        guard generationID == id, !Task.isCancelled else {
                            return
                        }
                        forkBoundary = boundary
                    } catch {
                        throw AssistantError.sideChatFailed(error.localizedDescription)
                    }
                } else if contextMode == .snapshot, snapshot == nil {
                    let context = try await reader.snapshot(for: chat)
                    guard generationID == id, !Task.isCancelled else {
                        return
                    }
                    snapshot = context
                }
                let currentConfiguration = try await reader.configuration(cwd: chat.cwd)
                guard generationID == id, !Task.isCancelled else {
                    return
                }
                configuration = currentConfiguration
                normalizeEffort()
                guard let modelID = resolvedModelID else {
                    throw AssistantError.generationFailed("没有可用模型，请重新连接 Codex 或在模型设置中选择模型。")
                }
                let images = roundAttachments + (update?.attachments ?? [])
                if !images.isEmpty, resolvedModel?.supportsImages != true {
                    throw AssistantError.imageUnsupported
                }
                let input = GenerationInput(mode: mode, chat: chat, snapshot: snapshot, roundID: roundID, forkBoundary: contextMode == .sideChat ? forkBoundary : nil, draft: initialDraft, answers: answers, remainingQuestions: remainingQuestions, feedback: feedback, previousCandidates: latestCandidates, attachments: images, questionCount: questionCount, candidatesOnly: candidatesOnly, configuration: currentConfiguration, modelID: modelID, effort: resolvedEffort, update: update, resolvedClarifications: currentResult?.resolvedClarifications ?? [:])
                loadingText = candidatesOnly ? "正在整理候选提示词…" : "正在理解你的想法…"
                let response = try await engine.generate(input) { [weak state = self] preview in
                    await state?.receivePreview(preview, id: id)
                }
                guard generationID == id, !Task.isCancelled else {
                    return
                }
                generationTiming?.validatedAt = Date()
                generationTiming?.outcome = "validated"
                streamingPreview = GenerationPreview()
                accept(response, update: update)
                isBusy = false
                generationTask = nil
            } catch is CancellationError {
                guard generationID == id else {
                    return
                }
                isBusy = false
                retryAvailable = true
                generationTiming?.outcome = "cancelled"
                information = "已停止生成，当前问答已保留。"
            } catch {
                guard generationID == id else {
                    return
                }
                isBusy = false
                retryAvailable = true
                // 重复正文不是可用结果；只清理本次预览，保留最近的已确认提示词。
                if case AssistantError.repetitiveOutput = error {
                    streamingPreview = GenerationPreview()
                }
                if case AssistantError.sideChatFailed = error {
                    sideChatFailed = true
                }
                generationTiming?.outcome = "failed"
                errorMessage = error.localizedDescription
                generationTask = nil
            }
        }
    }

    // 预览只更新当前请求，不改问答计数、活动选项或已确认候选。
    private func receivePreview(_ preview: GenerationPreview, id: UUID) {
        guard generationID == id, isBusy else {
            return
        }
        streamingPreview = preview
    }

    func markPreviewVisible() {
        guard generationTiming?.id == generationID, generationTiming?.firstPreviewAt == nil, !streamingPreview.isEmpty else {
            return
        }
        generationTiming?.firstPreviewAt = Date()
    }

    func markResultVisible(_ messageID: UUID) {
        guard pendingResultMessageID == messageID, generationTiming?.id == generationID, generationTiming?.resultVisibleAt == nil else {
            return
        }
        generationTiming?.resultVisibleAt = Date()
        generationTiming?.outcome = "visible"
    }

    private func accept(_ response: EngineResponse, update: RefinementUpdate? = nil) {
        if response.kind == "refinement" {
            // 在当前请求已校验成功后一次性确认答案、附图和正文。失败或取消都保留原表单。
            if let update {
                answers.append(contentsOf: update.answers)
                if !update.note.isEmpty { feedback.append(update.note) }
                roundAttachments.append(contentsOf: update.attachments)
                let summary = ([update.note] + update.answers.map { $0.question + " → " + $0.answer })
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                messages.append(ChatMessage(role: .user, text: summary.nonEmpty(or: "更新增强提示词"), attachments: update.attachments))
                clarificationDrafts.removeAll()
                pendingAttachments.removeAll()
                draft = ""
            }
            // 只有真正解决的旧题才归档。仅答了部分细节时，模型可以沿用原 ID 继续问缺失部分。
            var resolved = currentResult?.resolvedClarifications ?? [:]
            let newlyResolved = Set(response.resolvedQuestionIDs ?? [])
            for question in remainingQuestions where newlyResolved.contains(question.id) {
                resolved[question.id] = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let resolvedText = Set(resolved.values)
            let questions = (response.questions ?? []).filter {
                resolved[$0.id] == nil && !resolvedText.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            latestCandidates = response.candidates.map { PromptCandidate(id: UUID().uuidString, title: "增强版提示词", prompt: $0.prompt) }
            messages.append(ChatMessage(role: .assistant, text: "", candidates: latestCandidates, generatedPrompt: latestCandidates.first?.prompt, clarificationQuestions: questions, resolvedClarifications: resolved))
        } else if let question = response.question {
            let orderedOptions = question.options.filter { $0.id == question.recommendedID } + question.options.filter { $0.id != question.recommendedID }
            let normalized = ClarifyingQuestion(id: UUID().uuidString, text: question.text, options: orderedOptions, recommendedID: question.recommendedID)
            activeQuestion = normalized
            questionCount += 1
            messages.append(ChatMessage(role: .assistant, text: "", question: normalized, questionNumber: questionCount))
        } else {
            let candidates = response.candidates.map { PromptCandidate(id: UUID().uuidString, title: $0.title, prompt: $0.prompt) }
            activeQuestion = nil
            candidatesOnly = true
            latestCandidates = candidates
            messages.append(ChatMessage(role: .assistant, text: "整理了 \(candidates.count) 个可选方向。你可以编辑、复制或直接发送到 Codex。", candidates: candidates))
        }
        pendingResultMessageID = messages.last?.id
    }

    private func normalizeEffort() {
        guard !selectedEffort.isEmpty, let model = resolvedModel else {
            return
        }
        if !model.efforts.contains(where: { $0.id == selectedEffort }) {
            selectedEffort = ""
            information = "已按所选模型恢复默认推理强度。"
        }
    }

    // 图片始终由用户选入；不会抓取其他聊天或应用窗口。
    func pickImages() {
        guard !isBusy else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                addImage(url)
            }
        }
    }

    func addImage(_ url: URL) {
        guard !isBusy else {
            return
        }
        do {
            pendingAttachments.append(try attachments.importFile(url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pasteImage(_ image: NSImage) {
        guard !isBusy else {
            return
        }
        do {
            pendingAttachments.append(try attachments.importImage(image))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeImage(_ id: UUID) {
        guard !isBusy, let attachment = pendingAttachments.first(where: { $0.id == id }) else {
            return
        }
        pendingAttachments.removeAll { $0.id == id }
        attachments.remove([attachment])
    }

    // 捕获点击时的来源及已保存正文；旧轮次任务不能更新新卡片状态。
    func sendCandidate(_ candidate: PromptCandidate) {
        guard sendingCandidateID == nil, let chat = selectedChat, messages.contains(where: { $0.candidates.contains(where: { $0.id == candidate.id && $0.prompt == candidate.prompt }) }) else {
            return
        }
        sendingCandidateID = candidate.id
        deliveryNotice = nil
        deliveryTask = Task {
            defer {
                if sendingCandidateID == candidate.id {
                    sendingCandidateID = nil
                }
            }
            do {
                try await CodexCandidateSender.send(candidate.prompt, to: chat.id, reader: reader)
                try Task.checkCancellation()
                deliveryNotice = (candidate.id, "已发送到「" + chat.title + "」")
            } catch {
                if !Task.isCancelled {
                    deliveryNotice = (candidate.id, error.localizedDescription)
                }
            }
        }
    }

    func copyCandidate(_ candidate: PromptCandidate) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidate.prompt, forType: .string)
        copiedCandidateID = candidate.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedCandidateID == candidate.id {
                copiedCandidateID = nil
            }
        }
    }

    func saveCandidate(_ edit: CandidateEdit) {
        guard !edit.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        for messageIndex in messages.indices {
            if let candidateIndex = messages[messageIndex].candidates.firstIndex(where: { $0.id == edit.id }) {
                messages[messageIndex].candidates[candidateIndex].prompt = edit.prompt
            }
        }
        if let index = latestCandidates.firstIndex(where: { $0.id == edit.id }) {
            latestCandidates[index].prompt = edit.prompt
        }
        editingCandidate = nil
    }

    // 切换来源时缓存的轮次同样只在内存中，重启前也要提醒用户。
    var hasUnsavedRounds: Bool {
        isBusy || roundStarted || editingCandidate != nil || !draft.isEmpty || !messages.isEmpty ||
        !pendingAttachments.isEmpty || !clarificationDrafts.isEmpty || retryAvailable ||
        savedRounds.values.contains { round in
            round.roundStarted || !round.draft.isEmpty || !round.messages.isEmpty ||
            !round.pendingAttachments.isEmpty || !round.clarificationDrafts.isEmpty || round.retryAvailable
        }
    }

    func shutdown() async {
        deliveryTask?.cancel()
        generationTask?.cancel()
        configurationTask?.cancel()
        isConnecting = true
        await engine.shutdown()
        await reader.shutdown()
        attachments.cleanup()
    }
}

// 编辑副本在用户保存之前不会改变已生成的原文。
struct CandidateEdit: Identifiable {
    let id: String
    let title: String
    var prompt: String

    init(_ candidate: PromptCandidate) {
        id = candidate.id
        title = candidate.title
        prompt = candidate.prompt
    }
}
