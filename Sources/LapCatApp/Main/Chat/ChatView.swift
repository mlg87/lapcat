import AppKit
import LapCatCore
import LapCatLLM
import SwiftUI

/// Chat over one meeting (its Chat tab) or over many (the Ask window): the thread's history, the
/// streamed answer, citation links, a `/` recipe picker, Stop, and an error banner (plan §10.4).
struct ChatView: View {
    let scope: ChatScope
    /// Meeting id for `.meeting`, folder id for `.folder`, nil for `.global`.
    let scopeRef: String?
    /// Restricts folder/global context to meetings started in this range.
    var dateRange: ClosedRange<Date>?
    var placeholder = "Ask a question — type / for recipes"

    @Environment(AppState.self) private var appState
    @State private var messages: [ChatMessage] = []
    @State private var recipes: [Recipe] = []
    @State private var input = ""
    /// The question being answered and the answer streamed so far.
    @State private var pending: (question: String, answer: String)?
    @State private var streaming: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    private var threadKey: String { "\(scope.rawValue)|\(scopeRef ?? "")" }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Banner(systemImage: "exclamationmark.triangle", tint: .orange) {
                    Text(errorMessage).lineLimit(3)
                } actions: {
                    Button("Dismiss") { self.errorMessage = nil }
                }
            }
            transcript
            Divider()
            recipePicker
            inputRow
        }
        .environment(\.openURL, OpenURLAction(handler: openCitation))
        .task(id: threadKey) {
            await loadMessages()
            recipes = (try? await appState.store.recipes()) ?? []
        }
        .onDisappear { streaming?.cancel() }
    }

    // MARK: - Messages

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        ChatBubble(role: message.role, content: message.content)
                    }
                    if let pending {
                        ChatBubble(role: .user, content: pending.question)
                        if pending.answer.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                        } else {
                            ChatBubble(role: .assistant, content: pending.answer)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(12)
            }
            .overlay {
                if messages.isEmpty, pending == nil {
                    ContentUnavailableView(
                        "No questions yet", systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Ask anything, or type / for a recipe such as /follow-up."))
                }
            }
            .onChange(of: messages.count) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: pending?.answer) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private static let bottomID = "chat-bottom"

    // MARK: - Input

    @ViewBuilder
    private var recipePicker: some View {
        if let suggestions = RecipeFilter.suggestions(for: input, in: recipes), !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { recipe in
                    Button {
                        send(recipe.prompt)
                    } label: {
                        HStack(spacing: 8) {
                            Text(recipe.slashCommand).font(.body.monospaced())
                            Text(recipe.name).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(recipe.slashCommand) \(recipe.name)")
                }
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5))
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { submit() }
            if streaming != nil {
                Button("Stop") { streaming?.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Send") { submit() }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    /// Enter on an exact slash command sends that recipe's prompt; anything else is sent as typed.
    private func submit() {
        if let recipe = RecipeFilter.recipe(matching: input, in: recipes) {
            send(recipe.prompt)
        } else {
            send(input)
        }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, streaming == nil else { return }
        input = ""
        errorMessage = nil
        pending = (question, "")
        let service = ChatService(store: appState.store, router: appState.llm.router)
        let (scope, scopeRef, dateRange) = (scope, scopeRef, dateRange)
        streaming = Task {
            do {
                for try await delta in service.ask(
                    scope: scope, scopeRef: scopeRef, question: question, dateRange: dateRange)
                {
                    pending?.answer += delta
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            await loadMessages()
            pending = nil
            streaming = nil
            inputFocused = true
        }
    }

    private func loadMessages() async {
        do {
            let thread = try await appState.store.thread(for: scope, scopeRef: scopeRef)
            messages = try await appState.store.messages(threadID: thread.id)
        } catch {
            errorMessage = "Could not load the chat: \(error.localizedDescription)"
        }
    }

    // MARK: - Citations

    private func openCitation(_ url: URL) -> OpenURLAction.Result {
        if scope == .meeting, let meetingID = scopeRef {
            guard let action = CitationLinkAction(url: url, currentMeetingID: meetingID) else { return .systemAction }
            appState.navigation.handle(action)
            return .handled
        }
        // Outside a meeting a bare `[[s:ID]]` names no meeting; look up the segment's owner.
        switch Citations.target(of: url) {
        case .meetingSegment(let ref):
            appState.openMeeting(ref.meetingID, segmentID: ref.segmentID)
        case .segment(let id):
            let store = appState.store
            Task {
                guard let segment = try? await store.segments(ids: [id]).first else { return }
                appState.openMeeting(segment.meetingID, segmentID: id)
            }
        case nil:
            return .systemAction
        }
        return .handled
    }
}

private struct ChatBubble: View {
    let role: ChatRole
    let content: String

    var body: some View {
        switch role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
            EnhancedMarkdown(markdown: content, kinds: Array(repeating: .mine, count: lines))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                // Citation links need non-selectable text (see `EnhancedMarkdown`); copy from the menu instead.
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    }
                }
        }
    }
}

extension AppState {
    /// Shows `meetingID`'s transcript at `segmentID` in the main window, opening it if needed.
    func openMeeting(_ meetingID: String, segmentID: Int64?) {
        navigation.show(meetingID: meetingID, segmentID: segmentID)
        showMainWindow()
    }
}
