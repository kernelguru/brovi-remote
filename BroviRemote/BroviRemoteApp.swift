import SwiftUI

@main
struct BroviRemoteApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var host: String = UserDefaults.standard.string(forKey: "host") ?? "192.168.8.1"
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? "admin"
    @Published private(set) var client: RouterClient?

    func login(password: String) async throws {
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

    func logout() async {
        try? await client?.logout()
        client = nil
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
                ExplorerView(client: client)
                    .tabItem { Label("API", systemImage: "terminal") }
            }
        } else {
            LoginView()
        }
    }
}
