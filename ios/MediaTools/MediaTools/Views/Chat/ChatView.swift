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

        withAnimation(Theme.springSnappy) {
            messages.append(ChatMessage(id: UUID().uuidString, role: "user", content: text))
        }
        input = ""
        isSending = true
        Haptics.light()

        do {
            let response = try await service.chat(itemType: itemType, itemId: itemId, message: text)
            withAnimation(Theme.springGentle) {
                messages = response.messages
            }
        } catch {
            self.error = error.localizedDescription
            withAnimation(Theme.springSnappy) {
                messages.append(ChatMessage(
                    id: UUID().uuidString,
                    role: "assistant",
                    content: "Sorry, something went wrong. Please try again."
                ))
            }
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
            }
            .textSelection(.enabled)

            if !isUser { Spacer(minLength: 60) }
        }
    }
}
