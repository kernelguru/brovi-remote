import SwiftUI

@main
struct BroviRemoteApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.cyan)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var host: String = UserDefaults.standard.string(forKey: "host") ?? "192.168.8.1"
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? "admin"
    @Published private(set) var client: RouterClient?
    /// Für welches Konto (benutzer@host) ein Passwort im Schlüsselbund liegt.
    @Published private(set) var savedAccount: String? = UserDefaults.standard.string(forKey: "savedAccount")
    @Published private(set) var isUnlocking = false

    private var didAttemptAutoUnlock = false

    var hasSavedLogin: Bool { savedAccount != nil }

    func login(password: String, remember: Bool) async throws {
        try await connect(password: password)
        let account = "\(username)@\(host)"
        if remember {
            do {
                try CredentialStore.save(password: password, account: account)
                setSavedAccount(account)
            } catch {
                setSavedAccount(nil)
            }
        } else {
            forgetSavedLogin()
        }
    }

    /// Meldet mit dem gespeicherten Passwort an (Face ID). Wirft `CancellationError` bei Abbruch.
    func unlockWithSavedLogin() async throws {
        guard let account = savedAccount else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        guard let password = try await CredentialStore.load(account: account, reason: "Beim Router anmelden") else {
            setSavedAccount(nil)
            throw RouterError(code: nil, message: "Keine gespeicherten Anmeldedaten gefunden")
        }
        if let at = account.lastIndex(of: "@") {
            username = String(account[..<at])
            host = String(account[account.index(after: at)...])
        }
        try await connect(password: password)
    }

    /// Einmal pro App-Start automatisch per Face ID anmelden.
    func autoUnlockIfNeeded() async -> String? {
        guard !didAttemptAutoUnlock, client == nil, hasSavedLogin else { return nil }
        didAttemptAutoUnlock = true
        do {
            try await unlockWithSavedLogin()
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func logout() async {
        didAttemptAutoUnlock = true
        try? await client?.logout()
        client = nil
    }

    func forgetSavedLogin() {
        if let savedAccount { CredentialStore.delete(account: savedAccount) }
        setSavedAccount(nil)
    }

    private func connect(password: String) async throws {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let urlString = trimmed.hasPrefix("http") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: urlString) else {
            throw RouterError(code: nil, message: "Ungültige Adresse")
        }
        let newClient = RouterClient(baseURL: url)
        try await newClient.login(username: username, password: password)
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(username, forKey: "username")
        client = newClient
    }

    private func setSavedAccount(_ account: String?) {
        savedAccount = account
        UserDefaults.standard.set(account, forKey: "savedAccount")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let client = model.client {
            TabView {
                StatusView(client: client)
                    .tabItem { Label("Funk", systemImage: "antenna.radiowaves.left.and.right") }
                NetworkView(client: client)
                    .tabItem { Label("Netz", systemImage: "slider.horizontal.3") }
                LockView(client: client)
                    .tabItem { Label("Sperre", systemImage: "lock.shield") }
                ExplorerView(client: client)
                    .tabItem { Label("API", systemImage: "terminal") }
            }
            .minimizingTabBar()
        } else {
            LoginView()
        }
    }
}
