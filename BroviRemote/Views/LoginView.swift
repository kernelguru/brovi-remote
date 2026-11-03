import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var remember = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 28) {
                    header
                    form
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task {
            if let message = await model.autoUnlockIfNeeded() {
                error = message
            }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .glassCircle()
            Text("Brovi Remote")
                .font(.largeTitle.bold())
            Text("H153-381 5G")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(spacing: 14) {
            GlassField(icon: "network", placeholder: "IP-Adresse", text: $model.host)
                .keyboardType(.URL)
            GlassField(icon: "person", placeholder: "Benutzer", text: $model.username)
            GlassField(icon: "key", placeholder: "Passwort", text: $password, secure: true)
                .submitLabel(.go)
                .onSubmit { Task { await login() } }

            Toggle(isOn: $remember) {
                Label("Mit \(CredentialStore.biometryName) merken", systemImage: CredentialStore.biometryIcon)
            }
            .padding(.horizontal, 4)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            Button {
                Task { await login() }
            } label: {
                HStack {
                    if busy { ProgressView() }
                    Text("Anmelden").bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .glassProminentButton()
            .disabled(busy || password.isEmpty)

            if model.hasSavedLogin {
                Button {
                    Task { await unlock() }
                } label: {
                    HStack {
                        if model.isUnlocking { ProgressView() }
                        Label("Mit \(CredentialStore.biometryName) anmelden", systemImage: CredentialStore.biometryIcon)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .glassButton()
                .disabled(model.isUnlocking)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 28)
    }

    private func login() async {
        guard !password.isEmpty else { return }
        busy = true
        error = nil
        do {
            try await model.login(password: password, remember: remember)
            password = ""
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func unlock() async {
        error = nil
        do {
            try await model.unlockWithSavedLogin()
        } catch is CancellationError {
            // Face ID abgebrochen
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Eingabefeld mit Symbol auf leicht aufgehelltem Glasgrund.
struct GlassField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
    }
}
