import AppKit
import LapCatCore
import SwiftUI

/// "Ask across meetings": chat over all meetings, one folder, or meetings in a date range.
struct AskWindow: View {
    enum Scope: Hashable {
        case all
        case folder(String)
        case dateRange
    }

    @Environment(AppState.self) private var appState
    @State private var scope: Scope = .all
    @State private var folders: [Folder] = []
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Scope", selection: $scope) {
                    Text("All meetings").tag(Scope.all)
                    if !folders.isEmpty {
                        Divider()
                        ForEach(folders) { folder in
                            Text("Folder: \(folder.name)").tag(Scope.folder(folder.id))
                        }
                        Divider()
                    }
                    Text("Date range").tag(Scope.dateRange)
                }
                .fixedSize()
                if scope == .dateRange {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                Spacer()
            }
            .padding(10)
            Divider()
            ChatView(
                scope: chatScope, scopeRef: scopeRef, dateRange: dateRange,
                placeholder: "Ask across your meetings — type / for recipes")
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity, minHeight: 420, idealHeight: 600, maxHeight: .infinity)
        .task {
            folders = (try? await appState.store.folders()) ?? []
        }
    }

    private var chatScope: ChatScope {
        if case .folder = scope { return .folder }
        return .global
    }

    private var scopeRef: String? {
        if case .folder(let id) = scope { return id }
        return nil
    }

    /// Whole days from the earlier to the later picked date.
    private var dateRange: ClosedRange<Date>? {
        guard scope == .dateRange else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(from, to))
        let endDay = calendar.startOfDay(for: max(from, to))
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) ?? endDay
        return start...end
    }
}

extension WindowID {
    static let ask = "ask"
}

extension AppState {
    /// Opens the "Ask across meetings" window.
    func showAskWindow() {
        windows.show(id: WindowID.ask, title: "Ask across meetings", size: NSSize(width: 640, height: 600), resizable: true) {
            AskWindow().environment(self)
        }
    }
}
