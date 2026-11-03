import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Router") {
                    TextField("IP-Adresse", text: $model.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Benutzer", text: $model.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $password)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack {
                            Text("Anmelden")
                            if busy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(busy || password.isEmpty)
                }
            }
            .navigationTitle("Brovi Remote")
        }
    }

    private func login() async {
        busy = true
        error = nil
        do {
            try await model.login(password: password)
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
