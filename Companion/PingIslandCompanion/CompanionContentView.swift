import SwiftUI

struct CompanionContentView: View {
    @EnvironmentObject private var relayStore: CompanionRelayStore

    var body: some View {
        NavigationStack {
            List {
                Section("Relay") {
                    TextField("Server URL", text: $relayStore.serverURLString)
                        .textInputAutocapitalization(.never)
                    TextField("Pairing code", text: $relayStore.pairingCode)
                        .keyboardType(.numberPad)
                    Button("Pair") {
                        Task { await relayStore.pair() }
                    }
                    Text(relayStore.status)
                }

                Section("Sessions") {
                    ForEach(relayStore.events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title)
                                .font(.headline)
                            Text(event.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if event.kind == "permission" {
                                HStack {
                                    Button("Allow") {
                                        Task {
                                            await relayStore.send(decision: CompanionPermissionResponse(
                                                sessionID: event.sessionID,
                                                toolUseID: event.payload["toolUseID"],
                                                decision: "allow",
                                                text: nil
                                            ))
                                        }
                                    }
                                    Button("Deny", role: .destructive) {
                                        Task {
                                            await relayStore.send(decision: CompanionPermissionResponse(
                                                sessionID: event.sessionID,
                                                toolUseID: event.payload["toolUseID"],
                                                decision: "deny",
                                                text: nil
                                            ))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ping Island")
        }
    }
}
