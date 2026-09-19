import SwiftUI
import CatchTallyKit

/// Skeleton root view. The Quick Tally vertical slice (issue #3) replaces
/// this; the real UI is routed through `TallyWorkspaceLayout` (issue #4).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Catch Tally")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text(CatchTallyKit.milestone)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
}
