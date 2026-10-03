import LapCatCore
import SwiftUI

/// The sidebar's filter popover: folder, starred only, date range and person.
struct SidebarFilterButton: View {
    @Environment(SidebarOrganizer.self) private var organizer
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(
                systemName: organizer.listFilter.isActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .help("Filter meetings")
        .accessibilityLabel("Filter meetings")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            FilterForm().environment(organizer)
        }
    }
}

private struct FilterForm: View {
    @Environment(SidebarOrganizer.self) private var organizer

    var body: some View {
        @Bindable var organizer = organizer
        Form {
            Picker("Folder", selection: $organizer.listFilter.folderID) {
                Text("All meetings").tag(String?.none)
                ForEach(organizer.folders) { folder in
                    Text(folder.name).tag(String?.some(folder.id))
                }
            }
            Toggle("Starred only", isOn: $organizer.listFilter.starredOnly)
            Picker("Date", selection: $organizer.listFilter.dateScope) {
                ForEach(MeetingListFilter.DateScope.allCases, id: \.self) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            if organizer.listFilter.dateScope == .custom {
                DatePicker("From", selection: $organizer.listFilter.customStart, displayedComponents: .date)
                DatePicker("To", selection: $organizer.listFilter.customEnd, displayedComponents: .date)
            }
            TextField("Person", text: $organizer.listFilter.personName, prompt: Text("Participant name"))
            HStack {
                Spacer()
                Button("Clear Filters") { organizer.listFilter = MeetingListFilter() }
                    .disabled(!organizer.listFilter.isActive)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}
