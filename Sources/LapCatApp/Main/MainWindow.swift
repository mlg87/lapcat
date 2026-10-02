import SwiftUI

struct MainWindow: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cat").font(.largeTitle).foregroundStyle(.secondary)
            Text("No meetings yet").font(.title2.bold())
            Text("Meetings you record appear here.").foregroundStyle(.secondary)
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }
}
