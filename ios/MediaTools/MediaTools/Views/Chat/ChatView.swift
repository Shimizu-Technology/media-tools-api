import SwiftUI

struct ChatView: View {
    let itemType: String
    let itemId: String

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    private let service = MediaToolsService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages, id: \.stableId) { message in
                            ChatBubble(message: message)
                                .id(message.stableId)
                        }

                        if isSending {
                            HStack {
                                ProgressView()
                                    .padding(.horizontal, 8)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    withAnimation {
                        proxy.scrollTo(messages.last?.stableId, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                TextField("Ask about this content...", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { Task { await send() } }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(input.isEmpty || isSending ? .secondary : .teal)
                }
                .disabled(input.isEmpty || isSending)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .task { await loadHistory() }
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

        // Optimistic: add user message
        messages.append(ChatMessage(id: UUID().uuidString, role: "user", content: text))
        input = ""
        isSending = true

        do {
            let response = try await service.chat(itemType: itemType, itemId: itemId, message: text)

            // Replace messages with server response (includes full history)
            messages = response.messages
        } catch {
            self.error = error.localizedDescription
            // Add error message
            messages.append(ChatMessage(
                id: UUID().uuidString,
                role: "assistant",
                content: "Sorry, something went wrong. Please try again."
            ))
        }

        isSending = false
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.teal : Color.secondary.opacity(0.12))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .textSelection(.enabled)

            if !isUser { Spacer(minLength: 60) }
        }
    }
}
