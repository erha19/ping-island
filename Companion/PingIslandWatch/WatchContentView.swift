import SwiftUI

struct WatchContentView: View {
    let latestTitle: String
    let latestBody: String
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(latestTitle)
                .font(.headline)
            Text(latestBody)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Allow", action: allow)
                Button("Deny", role: .destructive, action: deny)
            }
        }
        .padding()
    }
}
