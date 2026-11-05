import SwiftUI

/// SMS lesen, senden und löschen (/api/sms/*).
/// Die Weboberfläche dieses Routers verschickt SMS mit Client-Schlüssel („;enc“) und
/// liest Listen teils verschlüsselt – die App probiert Klartext und Verschlüsselung nacheinander.
struct SmsView: View {
    let client: RouterClient

    struct Message: Identifiable, Hashable {
        let id: String
        let phone: String
        let content: String
        let date: String
        var unread: Bool
    }

    @State private var outbox = false
    @State private var messages: [Message] = []
    @State private var unreadCount: String?
    @State private var loading = false
    @State private var error: String?
    @State private var composing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Ordner", selection: $outbox) {
                        Text("Eingang").tag(false)
                        Text("Gesendet").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    if messages.isEmpty && !loading && error == nil {
                        Text("Keine Nachrichten").foregroundStyle(.secondary)
                    }
                    ForEach($messages) { $message in
                        NavigationLink {
                            SmsDetailView(client: client, message: $message)
                        } label: {
                            SmsRow(message: message)
                        }
                    }
                    .onDelete { offsets in Task { await delete(offsets) } }
                } header: {
                    if let unreadCount, unreadCount != "0", !outbox {
                        Text("\(unreadCount) ungelesen")
                    }
                }
            }
            .appBackground()
            .navigationTitle("SMS")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .overlay { if loading && messages.isEmpty { ProgressView() } }
            .refreshable { await load() }
            .task(id: outbox) { await load() }
            .sheet(isPresented: $composing) {
                SmsComposeView(client: client) { Task { await load() } }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        unreadCount = (try? await client.get("/api/sms/sms-count"))?["LocalUnread"]
        let inner = "<PageIndex>1</PageIndex><ReadCount>50</ReadCount><BoxType>\(outbox ? 2 : 1)</BoxType>"
            + "<SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred>"
        do {
            let node: XMLNode
            do {
                node = try await client.post("/api/sms/sms-list", inner)
            } catch let plainError as RouterError where !RouterError.sessionErrors.contains(plainError.code ?? "") {
                node = try await client.postEncrypted("/api/sms/sms-list", inner, encryption: .response)
            }
            messages = (node.child("Messages")?.children(named: "Message") ?? []).map { item in
                Message(id: item["Index"] ?? UUID().uuidString,
                        phone: item["Phone"] ?? "",
                        content: item["Content"] ?? "",
                        date: item["Date"] ?? "",
                        unread: item["Smstat"] == "0")
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ offsets: IndexSet) async {
        for index in offsets.sorted(by: >) {
            let message = messages[index]
            do {
                _ = try await client.post("/api/sms/delete-sms", "<Index>\(message.id.xmlEscaped)</Index>")
                messages.remove(at: index)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct SmsRow: View {
    let message: SmsView.Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.unread ? Theme.cyan : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.phone).font(.headline)
                    Spacer()
                    Text(message.date).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct SmsDetailView: View {
    let client: RouterClient
    @Binding var message: SmsView.Message
    @State private var replying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(message.date).font(.caption).foregroundStyle(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 20)
            }
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle(message.phone)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Antworten") { replying = true }
            }
        }
        .sheet(isPresented: $replying) {
            SmsComposeView(client: client, phone: message.phone) {}
        }
        .task {
            guard message.unread else { return }
            if (try? await client.post("/api/sms/set-read", "<Index>\(message.id.xmlEscaped)</Index>")) != nil {
                message.unread = false
            }
        }
    }
}

private struct SmsComposeView: View {
    let client: RouterClient
    @State var phone = ""
    let onSent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    init(client: RouterClient, phone: String = "", onSent: @escaping () -> Void) {
        self.client = client
        self._phone = State(initialValue: phone)
        self.onSent = onSent
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    TextField("Rufnummer", text: $phone)
                        .keyboardType(.phonePad)
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                } footer: {
                    Text("\(text.count) Zeichen")
                }
            }
            .appBackground()
            .navigationTitle("Neue SMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Senden") { Task { await send() } }
                            .disabled(phone.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty)
                    }
                }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let numbers = phone.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let phones = numbers.map { "<Phone>\($0.xmlEscaped)</Phone>" }.joined()
        let inner = "<Index>-1</Index><Phones>\(phones)</Phones><Sca></Sca>"
            + "<Content>\(text.xmlEscaped)</Content><Length>\(text.count)</Length>"
            + "<Reserved>1</Reserved><Date>\(formatter.string(from: Date()))</Date>"
        do {
            do {
                _ = try await client.postEncrypted("/api/sms/send-sms", inner, encryption: .keyOnly, timeout: 30)
            } catch let encError as RouterError where !RouterError.sessionErrors.contains(encError.code ?? "") {
                _ = try await client.post("/api/sms/send-sms", inner, timeout: 30)
            }
            onSent()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
