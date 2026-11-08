import AppKit
import ApplicationServices

// 只由正式候选的发送按钮调用，来源历史和生成进程继续使用各自原有的权限。
@MainActor
enum CodexCandidateSender {
    static func send(_ prompt: String, to threadID: String, reader: CodexReader) async throws {
        guard UUID(uuidString: threadID) != nil, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            throw AssistantError.generationFailed("无法定位来源对话或 Codex 桌面应用，未发送。")
        }
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
            throw AssistantError.generationFailed("未发送。请在「系统设置 → 隐私与安全性 → 辅助功能」允许提示词助手控制 Codex，再点击发送。")
        }
        let initial = try await reader.latestDeliveryTurn(threadID: threadID)
        guard initial?["status"]?.stringValue != "inProgress" else {
            throw AssistantError.generationFailed("来源对话正在回答。请等它完成后再发送，原草稿已保留。")
        }
        try Task.checkCancellation()
        // 单次标记只能由带目标 ID 的深链写入，防止切换尚未完成时误操作另一个同名聊天。
        let marker = "提示词助手正在填入候选（" + UUID().uuidString + "）"
        let app = try await prefill(marker, threadID: threadID, appURL: appURL)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        let editor: AXUIElement
        do {
            editor = try await waitForEditor(root, text: marker)
        } catch {
            // 路由没有得到确认时，也让目标草稿落回候选正文；这个分支绝不提交。
            if !Task.isCancelled {
                _ = try? await prefill(prompt, threadID: threadID, appURL: appURL)
            }
            throw error
        }
        // 原生预填会更新 Codex 编辑器自身的草稿状态；全文回读通过后才允许按发送。
        // 带首尾空白的正文会被深链解析器 trim，改用已核实的输入框原样填写。
        if prompt != prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard ownsDraft(root, editor, marker), AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, prompt as CFString) == .success else {
                throw AssistantError.generationFailed("Codex 未能原样填入包含首尾空白的候选，未发送。")
            }
        } else {
            _ = try await prefill(prompt, threadID: threadID, appURL: appURL)
        }
        let verified = try await waitForEditor(root, text: prompt)
        // 在点击前记录最新轮次，避免把准备草稿期间已出现的同文消息当作本次回执。
        let previous = try await reader.latestDeliveryTurn(threadID: threadID)
        guard previous?["status"]?.stringValue != "inProgress" else {
            throw AssistantError.generationFailed("来源对话已开始处理其他消息，未发送。候选已填入来源输入框。")
        }
        guard CFEqual(verified, editor), let button = try sendButton(for: editor), ownsDraft(root, editor, prompt) else {
            throw AssistantError.generationFailed("来源输入框已切换，或发送按钮不可用。未发送，请检查 Codex 中的草稿。")
        }
        try Task.checkCancellation()
        let press = AXUIElementPerformAction(button, kAXPressAction as CFString)
        // 辅助功能超时也可能已触发点击；只提交一次，再由来源聊天的新用户消息确认。
        guard press == .success || press == .cannotComplete else {
            throw AssistantError.generationFailed("Codex 未接受发送按钮操作，请检查来源输入框。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        do {
            repeat {
                try await Task.sleep(for: .milliseconds(500))
                if let turn = try await reader.latestDeliveryTurn(threadID: threadID), turn["id"]?.stringValue != previous?["id"]?.stringValue {
                    if let full = try await reader.latestDeliveryTurn(threadID: threadID, full: true), full["id"]?.stringValue == turn["id"]?.stringValue, full["items"]?.arrayValue?.contains(where: { item in
                        guard item["type"]?.stringValue == "userMessage", let parts = item["content"]?.arrayValue, parts.allSatisfy({ $0["type"]?.stringValue == "text" }) else {
                            return false
                        }
                        return parts.compactMap { $0["text"]?.stringValue }.joined() == prompt
                    }) == true {
                        return
                    }
                }
            } while ContinuousClock.now < deadline
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AssistantError.generationFailed("已尝试发送，但读取来源回执失败：\(error.localizedDescription) 请先查看来源对话，避免重复发送。")
        }
        throw AssistantError.generationFailed("已尝试发送，但尚未在来源对话确认这条正文。请先查看 Codex，避免重复发送。")
    }

    // 将正文作为一个查询参数编码，确保换行、&、# 和中文不会改变目标路径。
    private static func prefill(_ text: String, threadID: String, appURL: URL) async throws -> NSRunningApplication {
        var route = URLComponents()
        route.scheme = "codex"
        route.host = "threads"
        route.path = "/" + threadID
        route.queryItems = [URLQueryItem(name: "prompt", value: text)]
        // URLSearchParams 会把未转义的加号解成空格（例如 C++）。
        route.percentEncodedQuery = route.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let link = route.url else {
            throw AssistantError.generationFailed("无法打开指定的来源对话，未发送。")
        }
        do {
            return try await NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: .init())
        } catch {
            throw AssistantError.generationFailed("未发送，Codex 无法打开来源输入框：" + error.localizedDescription)
        }
    }

    // 只读取 Codex 当前聚焦的 ProseMirror 输入框，不搜索其他窗口，也不投递全局按键。
    private static func waitForEditor(_ root: AXUIElement, text: String) async throws -> AXUIElement {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            try Task.checkCancellation()
            if let editor = element(root, kAXFocusedUIElementAttribute), ownsDraft(root, editor, text) {
                return editor
            }
            try await Task.sleep(for: .milliseconds(120))
        } while ContinuousClock.now < deadline
        throw AssistantError.generationFailed("未能核实所选 Codex 对话的输入框和草稿全文，未发送。请检查 Codex 窗口及辅助功能权限。")
    }

    private static func ownsDraft(_ root: AXUIElement, _ editor: AXUIElement, _ text: String) -> Bool {
        guard let focused = element(root, kAXFocusedUIElementAttribute), CFEqual(focused, editor), attribute(editor, kAXRoleAttribute) as? String == "AXTextArea", (attribute(editor, "AXDOMClassList") as? [String])?.contains("ProseMirror") == true else {
            return false
        }
        return attribute(editor, kAXValueAttribute) as? String == text
    }

    // 在输入框所属的工具栏内匹配明确的发送按钮，遇到停止、排队或未知控件时不点击。
    private static func sendButton(for editor: AXUIElement) throws -> AXUIElement? {
        var ancestor = element(editor, kAXParentAttribute)
        while let current = ancestor {
            if (attribute(current, "AXDOMClassList") as? [String])?.contains(where: { $0.hasPrefix("footer-") || $0.hasPrefix("ComposerLayoutRoot-") }) == true {
                var stack = [current]
                var matches: [AXUIElement] = []
                while let node = stack.popLast() {
                    // 附图和引用属于独立控件，覆盖文字后不能把旧附件一并发出。
                    let classes = attribute(node, "AXDOMClassList") as? [String] ?? []
                    if classes.contains(where: { $0.hasPrefix("ComposerAttachmentsScrollContainer-") || $0.hasPrefix("ComposerLayoutReplyContext-") }), !(attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).isEmpty {
                        throw AssistantError.generationFailed("目标草稿仍有附件或引用，未发送。请在 Codex 移除后重新发送。")
                    }
                    if attribute(node, kAXRoleAttribute) as? String == "AXButton", attribute(node, kAXEnabledAttribute) as? Bool == true, ["发送", "傳送", "傳送訊息", "Send"].contains(attribute(node, kAXDescriptionAttribute) as? String ?? "") {
                        matches.append(node)
                    }
                    stack.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                }
                return matches.count == 1 ? matches.first : nil
            }
            ancestor = element(current, kAXParentAttribute)
        }
        return nil
    }

    private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func element(_ node: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}
