import SwiftUI

/// First-run screen, native and minimal.
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player

    var body: some View {
        @Bindable var app = app

        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.primary)

                        Text("Codec")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Connect to your sync server to stream your library.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }

                Section("Sync server") {
                    TextField("http://192.168.1.20:8787", text: $app.serverURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Auth token (optional)", text: $app.token)
                }

                Section {
                    Button {
                        Task {
                            await app.connect()
                            app.syncPlayer(player)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if app.connection == .connecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(app.connection == .connecting || app.serverURLString.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    if !app.errorMessage.isEmpty {
                        Text(app.errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
