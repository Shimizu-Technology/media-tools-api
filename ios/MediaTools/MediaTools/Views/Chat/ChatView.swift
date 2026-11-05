import SwiftUI

struct ChatView: View {
    let itemType: String
    let itemId: String
    let onCitationTap: ((Citation) -> Void)?
    @Environment(\.openURL) private var openURL
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var reportTarget: AIContentReportTarget?
    @FocusState private var inputFocused: Bool

    private let service = MediaToolsService.shared

    init(itemType: String, itemId: String, onCitationTap: ((Citation) -> Void)? = nil) {
        self.itemType = itemType
        self.itemId = itemId
        self.onCitationTap = onCitationTap
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(messages, id: \.stableId) { message in
                            ChatBubble(
                                message: message,
                                onCitationTap: openCitation,
                                onReport: beginReport
                            )
                                .id(message.stableId)
                        }

                        if isSending {
                            ProgressNote(text: "Thinking…")
                                .id("loading")
                        }
                    }
                    .readingMeasure()
                    .pageMargin()
                    .padding(.vertical)
                }
                .onChange(of: messages.count) {
                    withMotion(Theme.quick) {
                        proxy.scrollTo(messages.last?.stableId, anchor: .bottom)
                    }
                }
            }

            Hairline()

            // Input bar
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Theme.separator, lineWidth: 0.5)
                    }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Theme.accentFill, in: Circle())
                        .opacity(input.isEmpty || isSending ? 0.45 : 1)
                }
                .buttonStyle(PressFeedbackButtonStyle())
                .disabled(input.isEmpty || isSending)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat.send")
            }
            .pageMargin()
            .padding(.vertical, 8)
            .barBackground()
        }
        .background(Theme.background)
        .task { await loadHistory() }
        .onAppear { inputFocused = true }
        .sheet(item: $reportTarget) { target in
            AIContentReportSheet(target: target)
        }
        .alert("Couldn't send message", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "Please try again.")
        }
    }

    private func loadHistory() async {
        do {
            let response = try await service.getChatHistory(itemType: itemType, itemId: itemId)
            messages = response.messages
        } catch {
            // No history yet, that's fine
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard await aiProcessingConsent.requestPermission() else { return }
        guard !isSending else { return }

        let tempId = UUID().uuidString
        messages.append(ChatMessage(id: tempId, role: "user", content: text, citations: nil))
        input = ""
        isSending = true
        Haptics.light()

        do {
            let response = try await service.chat(itemType: itemType, itemId: itemId, message: text)
            // Remove the optimistic user message, then append the real pair
            messages.removeAll { $0.id == tempId }
            messages.append(contentsOf: response.messages)
        } catch {
            // Hand the message back so a failed send never loses what was typed.
            messages.removeAll { $0.id == tempId }
            if input.isEmpty {
                input = text
            }
            self.error = error.localizedDescription
        }

        isSending = false
    }

    private func openCitation(_ citation: Citation) {
        if let onCitationTap {
            onCitationTap(citation)
            return
        }

        var components = URLComponents(
            string: "\(Configuration.webAppURL)/app/items/\(citation.itemType)/\(citation.itemId)"
        )
        var queryItems: [URLQueryItem] = []
        if let startMs = citation.startMs {
            queryItems.append(URLQueryItem(name: "t", value: String(startMs / 1_000)))
        }
        if let pageNumber = citation.pageNumber {
            queryItems.append(URLQueryItem(name: "page", value: String(pageNumber)))
        }
        components?.queryItems = queryItems
        if let url = components?.url {
            openURL(url)
        }
    }

    private func beginReport(_ message: ChatMessage) {
        guard !message.role.isEmpty,
              message.role == "assistant",
              let messageID = message.id
        else { return }
        reportTarget = AIContentReportTarget(targetType: .chatMessage, targetId: messageID)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    let onCitationTap: (Citation) -> Void
    let onReport: (ChatMessage) -> Void

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Theme.accentFill,
                        in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                    )
                    .textSelection(.enabled)
            }
        } else {
            // An answer reads like the rest of the page, not like a message bubble.
            VStack(alignment: .leading, spacing: 2) {
                Text(message.content)
                    .readingText()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if let citations = message.citations, !citations.isEmpty {
                        CitationChips(citations: citations, onTap: onCitationTap)
                    }
                    Spacer(minLength: 0)
                    if message.id != nil {
                        // App Review expects AI reporting to be findable. It sits one
                        // tap away on every answer without interrupting the reading.
                        Menu {
                            Button {
                                onReport(message)
                            } label: {
                                Label("Report Response", systemImage: "flag")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Response actions")
                        .accessibilityHint("Includes reporting this AI response")
                    }
                }
            }
        }
    }
}
