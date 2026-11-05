import SwiftUI

/// Freier Zugriff auf die Router-API, um Endpunkte der Firmware zu erkunden.
struct ExplorerView: View {
    let client: RouterClient

    @State private var path = "/api/device/information"
    @State private var usePost = false
    @State private var postBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <request>
    </request>
    """
    @State private var response = ""
    @State private var busy = false

    private static let endpoints = [
        "/api/device/information",
        "/api/device/basic_information",
        "/api/device/signal",
        "/api/monitoring/status",
        "/api/monitoring/traffic-statistics",
        "/api/net/current-plmn",
        "/api/net/net-mode",
        "/api/net/net-mode-list",
        "/api/net/lock-freq",
        "/api/net/net-feature-switch",
        "/api/net/cell-info",
        "/api/device/nbrcellinfo",
        "/api/device/seccellinfo",
        "/config/network/bandfreqlist.xml",
        "/api/net/network",
        "/api/net/register",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Anfrage") {
                    TextField("Pfad", text: $path)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Menu("Bekannte Endpunkte") {
                        ForEach(Self.endpoints, id: \.self) { endpoint in
                            Button(endpoint) {
                                path = endpoint
                                usePost = false
                            }
                        }
                    }
                    Picker("Methode", selection: $usePost) {
                        Text("GET").tag(false)
                        Text("POST").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if usePost {
                        TextEditor(text: $postBody)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(minHeight: 120)
                    }
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Text("Senden")
                            if busy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(busy || path.isEmpty)
                }
                Section("Antwort") {
                    Text(response.isEmpty ? "–" : response)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .appBackground()
            .navigationTitle("API-Explorer")
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        do {
            response = try await client.raw(path: path, body: usePost ? postBody : nil)
        } catch {
            response = "Fehler: \(error.localizedDescription)"
        }
    }
}
