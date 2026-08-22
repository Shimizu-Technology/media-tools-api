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
                    LazyVStack(spacing: 12) {
                        ForEach(messages, id: \.stableId) { message in
                            ChatBubble(message: message, onCitationTap: openCitation)
                                .id(message.stableId)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }

                        if isSending {
                            HStack {
                                ProgressView()
                                    .tint(Theme.brand400)
                                    .padding(.horizontal, 8)
                                Text("Thinking...")
                                    .font(Theme.caption())
                                    .foregroundStyle(Theme.textMuted)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    withAnimation(Theme.springSnappy) {
                        proxy.scrollTo(messages.last?.stableId, anchor: .bottom)
                    }
                }
            }

            // Divider
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            // Input bar
            HStack(spacing: 8) {
                TextField("Ask about this content...", text: $input, axis: .vertical)
                    .textFieldStyle(.themed)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(input.isEmpty || isSending ? Theme.textMuted : Theme.brand500)
                }
                .disabled(input.isEmpty || isSending)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Theme.surfaceElevated)
            .animation(.easeOut(duration: 0.15), value: inputFocused)
        }
        .background(Theme.surface)
        .task { await loadHistory() }
    }

    private func loadHistory() async {
        do {
            let response = try await service.getChatHistory(itemType: itemType, itemId: itemId)
            withAnimation(Theme.springGentle) {
                messages = response.messages
            }
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
        withAnimation(Theme.springSnappy) {
            messages.append(ChatMessage(id: tempId, role: "user", content: text, citations: nil))
        }
        input = ""
        isSending = true
        Haptics.light()

        do {
            let response = try await service.chat(itemType: itemType, itemId: itemId, message: text)
            withAnimation(Theme.springGentle) {
                // Remove the optimistic user message, then append the real pair
                messages.removeAll { $0.id == tempId }
                messages.append(contentsOf: response.messages)
            }
        } catch {
            self.error = error.localizedDescription
            withAnimation(Theme.springSnappy) {
                messages.append(ChatMessage(
                    id: UUID().uuidString,
                    role: "assistant",
                    content: "Sorry, something went wrong. Please try again.",
                    citations: nil
                ))
            }
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
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    let onCitationTap: (Citation) -> Void

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(Theme.body(15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Theme.brand500 : Theme.surfaceCard)
                    .foregroundStyle(isUser ? .white : Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusLarge)
                            .stroke(isUser ? Color.clear : Theme.borderSubtle, lineWidth: 1)
                    )

                if !isUser, let citations = message.citations, !citations.isEmpty {
                    CitationChips(citations: citations, onTap: onCitationTap)
                }
            }
            .textSelection(.enabled)

            if !isUser { Spacer(minLength: 60) }
        }
    }
}
