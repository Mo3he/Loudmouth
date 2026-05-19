import SwiftUI
import CryptoKit
import AuthenticationServices

// MARK: - SourcesView
struct SourcesView: View {
    @EnvironmentObject var sources: SourceViewModel
    @State private var isAddingSource = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources.sources.filter { $0.kind != .wifiTransfer }) { source in
                    NavigationLink(destination: SourceDetailView(source: source)) {
                        SourceRowView(source: source)
                    }
                }
                .onDelete { offsets in
                    let visible = sources.sources.filter { $0.kind != .wifiTransfer }
                    offsets.forEach { sources.delete(sourceID: visible[$0].id) }
                }
                Section("Wi-Fi Transfer") {
                    WiFiTransferRow()
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAddingSource = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isAddingSource) { AddSourceView() }
        }
    }
}

// MARK: - SourceRowView
struct SourceRowView: View {
    let source: MusicSource
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(source.kind.tintColor.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: source.kind.systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName).font(.subheadline).fontWeight(.semibold)
                Text(source.kind.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !source.isEnabled {
                Image(systemName: "pause.circle.fill").foregroundStyle(.tertiary).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - WiFiTransferRow
struct WiFiTransferRow: View {
    @EnvironmentObject var sources: SourceViewModel
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.teal.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: "wifi")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Receive Files via Wi-Fi").font(.subheadline).fontWeight(.semibold)
                if sources.wifiTransferActive, let url = sources.wifiTransferURL {
                    Text(url).font(.caption).foregroundStyle(.green)
                } else {
                    Text("Open a browser on the same network to upload").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { sources.wifiTransferActive },
                set: { active in
                    if active { sources.startWiFiTransfer() }
                    else      { sources.stopWiFiTransfer()  }
                }
            ))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SourceDetailView  (edit existing source)
struct SourceDetailView: View {
    @State var source: MusicSource
    @EnvironmentObject var sources: SourceViewModel
    @State private var isScanningNow = false
    @State private var scanResult: String?
    @State private var showingFilePicker = false

    var body: some View {
        Form {
            Section {
                TextField("Display Name", text: $source.displayName)
                Toggle("Enabled", isOn: $source.isEnabled)
                Toggle("Pin for Offline", isOn: $source.isPinnedOffline)
            }
            configSection
            if source.kind != .wifiTransfer {
                Section {
                    Button {
                        isScanningNow = true
                        sources.scan(source: source) { result in
                            isScanningNow = false; scanResult = result
                        }
                    } label: {
                        if isScanningNow {
                            HStack { ProgressView(); Text("Scanning…").foregroundStyle(.secondary) }
                        } else {
                            Label("Scan Now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isScanningNow)
                    if let result = scanResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: source) { _, newSource in sources.update(source: newSource) }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            if let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                source.config = .local(LocalSourceConfig(bookmarkData: bookmark))
                sources.update(source: source)
            }
            url.stopAccessingSecurityScopedResource()
        }
    }

    @ViewBuilder
    private var configSection: some View {
        switch source.config {
        case .local(let cfg):
            Section("Folder") {
                if cfg.bookmarkData != nil {
                    Label("Folder selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("No folder selected").foregroundStyle(.secondary)
                }
                Button("Choose Folder") { showingFilePicker = true }
                Toggle("Watch for Changes", isOn: Binding(
                    get: { guard case .local(let c) = source.config else { return true }; return c.watchForChanges },
                    set: { v in guard case .local(var c) = source.config else { return }; c.watchForChanges = v; source.config = .local(c) }
                ))
            }
        case .subsonic:
            Section("Server") {
                TextField("https://music.example.com", text: subsonicURLBinding)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Username", text: subsonicUsernameBinding)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Password", text: subsonicPasswordBinding)
            }
        case .nas:
            Section("Connection") {
                TextField("192.168.1.100 or hostname", text: nasHostBinding)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Text("Port"); Spacer()
                    TextField("8200", value: nasPortBinding, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Picker("Protocol", selection: nasProtocolBinding) {
                    Text("DLNA / UPnP").tag(NASSourceConfig.NASProtocol.dlna)
                    Text("SMB / Samba").tag(NASSourceConfig.NASProtocol.smb)
                }
            }
        case .webRadio(let cfg):
            Section("Stations (\(cfg.stations.count))") {
                ForEach(cfg.stations) { station in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name).font(.subheadline)
                        Text(station.streamURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .onDelete { offsets in
                    guard case .webRadio(var c) = source.config else { return }
                    c.stations.remove(atOffsets: offsets)
                    source.config = .webRadio(c)
                }
                NavigationLink("Add Station") { AddRadioStationView(source: $source) }
            }
        case .cloud(let cfg):
            Section(cfg.provider.displayName) {
                if cfg.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if !cfg.accountID.isEmpty {
                        Text(cfg.accountID).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Disconnect", role: .destructive) {
                        guard case .cloud(var c) = source.config else { return }
                        c.isConnected = false; c.accountID = ""
                        KeychainHelper.shared.delete(key: c.keychainKey)
                        c.keychainKey = ""
                        source.config = .cloud(c)
                    }
                } else if cfg.provider == .iCloud {
                    Label("Uses your iCloud account — no sign-in needed", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if cfg.provider == .backblaze {
                    LabeledContent("Key ID") {
                        Text(cfg.accountID.isEmpty ? "Not set" : cfg.accountID)
                            .foregroundStyle(cfg.accountID.isEmpty ? .red : .primary)
                    }
                    LabeledContent("App Key") {
                        Text(cfg.keychainKey.isEmpty ? "Not set" : "••••••••")
                            .foregroundStyle(cfg.keychainKey.isEmpty ? .red : .primary)
                    }
                } else {
                    Button("Connect to \(cfg.provider.displayName)") {
                        Task {
                            guard let authURL = CloudOAuth.authorizationURL(for: cfg.provider) else { return }
                            guard let callbackURL = try? await ASWebAuthenticationSession.startSession(
                                url: authURL, callbackURLScheme: CloudOAuth.redirectScheme
                            ) else { return }
                            guard let token = try? await CloudOAuth.exchangeCode(from: callbackURL, provider: cfg.provider) else { return }
                            let key = "oauth_\(cfg.provider.rawValue)_\(UUID().uuidString)"
                            try? KeychainHelper.shared.save(key: key, value: token)
                            guard case .cloud(var c) = source.config else { return }
                            c.keychainKey = key; c.accountID = cfg.provider.displayName; c.isConnected = true
                            source.config = .cloud(c)
                            sources.update(source: source)
                        }
                    }
                }
            }
        case .wifiTransfer:
            EmptyView()
        }
    }

    private var subsonicURLBinding: Binding<String> {
        Binding(
            get: { guard case .subsonic(let c) = source.config else { return "" }; return c.serverURL },
            set: { v in guard case .subsonic(var c) = source.config else { return }; c.serverURL = v; source.config = .subsonic(c) }
        )
    }
    private var subsonicUsernameBinding: Binding<String> {
        Binding(
            get: { guard case .subsonic(let c) = source.config else { return "" }; return c.username },
            set: { v in guard case .subsonic(var c) = source.config else { return }; c.username = v; source.config = .subsonic(c) }
        )
    }
    private var subsonicPasswordBinding: Binding<String> {
        Binding(
            get: { guard case .subsonic(let c) = source.config else { return "" }; return (try? KeychainHelper.shared.read(key: c.keychainKey)) ?? "" },
            set: { val in
                guard case .subsonic(var c) = source.config else { return }
                let key = c.keychainKey.isEmpty ? "sub_\(source.id.rawValue)" : c.keychainKey
                try? KeychainHelper.shared.save(key: key, value: val)
                c.keychainKey = key; source.config = .subsonic(c)
            }
        )
    }
    private var nasHostBinding: Binding<String> {
        Binding(
            get: { guard case .nas(let c) = source.config else { return "" }; return c.host },
            set: { v in guard case .nas(var c) = source.config else { return }; c.host = v; source.config = .nas(c) }
        )
    }
    private var nasPortBinding: Binding<Int> {
        Binding(
            get: { guard case .nas(let c) = source.config else { return 8200 }; return c.port },
            set: { v in guard case .nas(var c) = source.config else { return }; c.port = v; source.config = .nas(c) }
        )
    }
    private var nasProtocolBinding: Binding<NASSourceConfig.NASProtocol> {
        Binding(
            get: { guard case .nas(let c) = source.config else { return .dlna }; return c.protocol_ },
            set: { v in guard case .nas(var c) = source.config else { return }; c.protocol_ = v; source.config = .nas(c) }
        )
    }
}

// MARK: - AddRadioStationView
struct AddRadioStationView: View {
    @Binding var source: MusicSource
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""
    @State private var genre = ""

    var body: some View {
        Form {
            Section("Station Info") {
                TextField("e.g. BBC Radio 6 Music", text: $name)
                TextField("Stream URL (http/https)", text: $urlString)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Genre (optional)", text: $genre)
            }
            Section {
                Text("Paste the direct stream URL — MP3, AAC, HLS or Icecast are all supported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add Station")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    guard !name.isEmpty, !urlString.isEmpty else { return }
                    if case .webRadio(var cfg) = source.config {
                        cfg.stations.append(WebRadioSourceConfig.RadioStation(
                            id: UUID(), name: name, streamURL: urlString, genre: genre
                        ))
                        source.config = .webRadio(cfg)
                    }
                    dismiss()
                }
                .disabled(name.isEmpty || urlString.isEmpty)
                .fontWeight(.semibold)
            }
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
        }
    }
}

// MARK: - AddSourceView  (step 1 wrapper)
struct AddSourceView: View {
    var body: some View {
        NavigationStack { SourceTypePickerView() }
    }
}

// MARK: - SourceTypePickerView  (step 1: choose kind)
struct SourceTypePickerView: View {
    @Environment(\.dismiss) private var dismiss

    private struct SourceOption: Identifiable {
        var id: MusicSourceKind { kind }
        let kind: MusicSourceKind
        let headline: String
        let detail: String
    }

    private let options: [SourceOption] = [
        .init(kind: .local,    headline: "Music on This Device",  detail: "Play files stored on your iPhone or iPad"),
        .init(kind: .nas,      headline: "NAS / DLNA Server",      detail: "Stream from a home server or network drive"),
        .init(kind: .subsonic, headline: "Subsonic / Navidrome",   detail: "Self-hosted music server with API access"),
        .init(kind: .webRadio, headline: "Web Radio",              detail: "Internet radio via stream URL"),
        .init(kind: .cloud,    headline: "Cloud Drive",            detail: "Dropbox, Google Drive, OneDrive and more"),
    ]

    var body: some View {
        List(options) { option in
            NavigationLink(destination: AddSourceConfigView(kind: option.kind)) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(option.kind.tintColor.gradient)
                            .frame(width: 50, height: 50)
                        Image(systemName: option.kind.systemImage)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.headline).font(.headline)
                        Text(option.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Add Music Source")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
        }
    }
}

// MARK: - AddSourceConfigView  (step 2: configure, then add)
struct AddSourceConfigView: View {
    let kind: MusicSourceKind
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var sources: SourceViewModel

    @State private var displayName = ""

    // Local
    @State private var showingFolderPicker = false
    @State private var localBookmark: Data?
    @State private var localFolderName = ""
    @State private var watchForChanges = true

    // Subsonic
    @State private var subURL = ""
    @State private var subUsername = ""
    @State private var subPassword = ""

    // NAS
    @State private var nasHost = ""
    @State private var nasPort = 8200
    @State private var nasProtocol: NASSourceConfig.NASProtocol = .dlna

    // Cloud
    @State private var cloudProvider: CloudProvider = .iCloud
    @State private var b2AccountID = ""
    @State private var b2AppKey = ""
    @State private var oauthConnected = false
    @State private var oauthAccountName = ""

    // Connection test
    enum ConnectionStatus { case idle, testing, success(String), failure(String) }
    @State private var connectionStatus: ConnectionStatus = .idle

    var body: some View {
        Form {
            Section("Name") {
                TextField(kind.defaultDisplayName, text: $displayName)
            }
            configFields
            if kind == .subsonic || kind == .nas {
                testConnectionSection
            }
            Section {
                Button { addSource(); dismiss() } label: {
                    HStack {
                        Spacer()
                        Text("Add \(kind.displayName)").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!isValid)
            }
        }
        .navigationTitle("Configure")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            localFolderName = url.lastPathComponent
            localBookmark = try? url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
            )
            url.stopAccessingSecurityScopedResource()
        }
    }

    @ViewBuilder
    private var configFields: some View {
        switch kind {
        case .local:
            Section("Folder") {
                if localBookmark != nil {
                    Label(localFolderName.isEmpty ? "Folder selected" : localFolderName,
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button(localBookmark == nil ? "Choose Folder" : "Change Folder") {
                    showingFolderPicker = true
                }
                Toggle("Watch for Changes", isOn: $watchForChanges)
            }

        case .subsonic:
            Section("Server") {
                TextField("https://music.example.com", text: $subURL)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: subURL) { _, _ in connectionStatus = .idle }
                TextField("Username", text: $subUsername)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: subUsername) { _, _ in connectionStatus = .idle }
                SecureField("Password", text: $subPassword)
                    .onChange(of: subPassword) { _, _ in connectionStatus = .idle }
            }

        case .nas:
            Section("Connection") {
                TextField("192.168.1.100 or hostname", text: $nasHost)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onChange(of: nasHost) { _, _ in connectionStatus = .idle }
                HStack {
                    Text("Port"); Spacer()
                    TextField("8200", value: $nasPort, format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Picker("Protocol", selection: $nasProtocol) {
                    Text("DLNA / UPnP").tag(NASSourceConfig.NASProtocol.dlna)
                    Text("SMB / Samba").tag(NASSourceConfig.NASProtocol.smb)
                }
            }

        case .webRadio:
            Section {
                Label(
                    "Add the source first, then open it to add your favourite stations.",
                    systemImage: "info.circle"
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }

        case .cloud:
            Section("Provider") {
                Picker("Service", selection: $cloudProvider) {
                    Text("iCloud Drive").tag(CloudProvider.iCloud)
                    Text("Backblaze B2").tag(CloudProvider.backblaze)
                    Text("Dropbox").tag(CloudProvider.dropbox)
                    Text("Google Drive").tag(CloudProvider.googleDrive)
                    Text("OneDrive").tag(CloudProvider.oneDrive)
                }
                .pickerStyle(.menu)
                .onChange(of: cloudProvider) { _, _ in oauthConnected = false; oauthAccountName = "" }
            }
            if cloudProvider == .iCloud {
                Section {
                    Label("Uses your Apple ID. No sign-in required.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else if cloudProvider == .backblaze {
                Section("Backblaze B2 Credentials") {
                    TextField("Key ID (e.g. 00aabbcc…)", text: $b2AccountID)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Application Key", text: $b2AppKey)
                }
                Section {
                    Text("Find your Key ID and Application Key in the Backblaze B2 console under App Keys.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    if oauthConnected {
                        Label(oauthAccountName.isEmpty
                              ? "Connected to \(cloudProvider.displayName)"
                              : oauthAccountName,
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Sign Out", role: .destructive) {
                            oauthConnected = false; oauthAccountName = ""
                            connectionStatus = .idle
                        }
                    } else {
                        Button("Connect to \(cloudProvider.displayName)") {
                            Task { await connectOAuth(provider: cloudProvider) }
                        }
                    }
                    if case .failure(let msg) = connectionStatus {
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }

        case .wifiTransfer:
            EmptyView()
        }
    }

    @ViewBuilder
    private var testConnectionSection: some View {
        Section {
            Button {
                Task {
                    if kind == .subsonic { await testSubsonicConnection() }
                    else if kind == .nas { await testNASConnection() }
                }
            } label: {
                if case .testing = connectionStatus {
                    HStack { ProgressView(); Text("Testing…").foregroundStyle(.secondary) }
                } else {
                    Label("Test Connection", systemImage: "network")
                }
            }
            .disabled({
                if case .testing = connectionStatus { return true }
                if kind == .subsonic { return subURL.isEmpty || subUsername.isEmpty || subPassword.isEmpty }
                if kind == .nas { return nasHost.isEmpty }
                return true
            }())

            switch connectionStatus {
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline)
            case .failure(let msg):
                Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.subheadline)
            default: EmptyView()
            }
        }
    }

    private var isValid: Bool {
        switch kind {
        case .local:        return localBookmark != nil
        case .subsonic:     return !subURL.isEmpty && !subUsername.isEmpty && !subPassword.isEmpty
        case .nas:          return !nasHost.isEmpty
        case .webRadio, .wifiTransfer: return true
        case .cloud:
            switch cloudProvider {
            case .iCloud:    return true
            case .backblaze: return !b2AccountID.isEmpty && !b2AppKey.isEmpty
            default:         return oauthConnected
            }
        }
    }

    private func addSource() {
        let name = displayName.isEmpty ? kind.defaultDisplayName : displayName
        let config: MusicSourceConfig
        switch kind {
        case .local:
            config = .local(LocalSourceConfig(bookmarkData: localBookmark, watchForChanges: watchForChanges))
        case .subsonic:
            let key = "sub_\(UUID().uuidString)"
            try? KeychainHelper.shared.save(key: key, value: subPassword)
            config = .subsonic(SubsonicSourceConfig(
                serverURL: subURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: subUsername,
                keychainKey: key
            ))
        case .nas:
            config = .nas(NASSourceConfig(host: nasHost, port: nasPort, protocol_: nasProtocol))
        case .webRadio:
            config = .webRadio(WebRadioSourceConfig(stations: []))
        case .cloud:
            var cfg = CloudSourceConfig(provider: cloudProvider)
            switch cloudProvider {
            case .iCloud:
                cfg.isConnected = true
                cfg.accountID = "iCloud Drive"
            case .backblaze:
                let key = "b2_\(UUID().uuidString)"
                try? KeychainHelper.shared.save(key: key, value: b2AppKey)
                cfg.accountID = b2AccountID
                cfg.keychainKey = key
                cfg.isConnected = true
            default:
                if oauthConnected {
                    let key = "oauth_\(cloudProvider.rawValue)_\(UUID().uuidString)"
                    // token already stored by connectOAuth — just record the key reference
                    cfg.keychainKey = key
                    cfg.accountID = oauthAccountName
                    cfg.isConnected = true
                }
            }
            config = .cloud(cfg)
        case .wifiTransfer:
            config = .wifiTransfer(WiFiTransferConfig())
        }
        sources.add(source: MusicSource(kind: kind, displayName: name, config: config))
    }

    // MARK: - Network tests

    private func testSubsonicConnection() async {
        connectionStatus = .testing
        guard var comps = URLComponents(string: subURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            connectionStatus = .failure("Invalid URL"); return
        }
        comps.path = "/rest/ping.view"
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let token = Insecure.MD5.hash(data: Data((subPassword + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        comps.queryItems = [
            URLQueryItem(name: "u", value: subUsername),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Loudmouth"),
            URLQueryItem(name: "f", value: "json"),
        ]
        guard let url = comps.url else { connectionStatus = .failure("Could not build request URL"); return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                connectionStatus = .failure("HTTP error from server"); return
            }
            struct Ping: Decodable {
                struct Body: Decodable { let status: String; let version: String }
                let subsonicResponse: Body
                enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" }
            }
            if let p = try? JSONDecoder().decode(Ping.self, from: data), p.subsonicResponse.status == "ok" {
                connectionStatus = .success("Connected — Subsonic API v\(p.subsonicResponse.version)")
            } else {
                connectionStatus = .failure("Wrong username or password")
            }
        } catch {
            connectionStatus = .failure(error.localizedDescription)
        }
    }

    private func testNASConnection() async {
        connectionStatus = .testing
        guard let url = URL(string: "http://\(nasHost):\(nasPort)/description.xml") else {
            connectionStatus = .failure("Invalid host or port"); return
        }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode < 400 {
                connectionStatus = .success("Server is reachable at \(nasHost):\(nasPort)")
            } else {
                connectionStatus = .failure("Server returned an error")
            }
        } catch {
            connectionStatus = .failure("Cannot reach \(nasHost):\(nasPort)")
        }
    }

    // MARK: - OAuth connect (Dropbox, Google Drive, OneDrive)
    private func connectOAuth(provider: CloudProvider) async {
        guard let authURL = CloudOAuth.authorizationURL(for: provider) else {
            connectionStatus = .failure("No client ID configured for \(provider.displayName)")
            return
        }
        do {
            let callbackURL = try await ASWebAuthenticationSession.startSession(
                url: authURL, callbackURLScheme: CloudOAuth.redirectScheme
            )
            let token = try await CloudOAuth.exchangeCode(from: callbackURL, provider: provider)
            let key = "oauth_\(provider.rawValue)_\(UUID().uuidString)"
            try KeychainHelper.shared.save(key: key, value: token)
            oauthConnected = true
            oauthAccountName = provider.displayName
            connectionStatus = .success("Connected to \(provider.displayName)")
        } catch {
            connectionStatus = .failure(error.localizedDescription)
        }
    }
}

// MARK: - CloudOAuth shared helpers
/// Register your app with each provider and replace the placeholder client IDs below.
private enum CloudOAuth {
    static let redirectScheme    = "loudmouth"
    static let dropboxClientID   = "YOUR_DROPBOX_APP_KEY"
    static let googleClientID    = "YOUR_GOOGLE_CLIENT_ID"
    static let microsoftClientID = "YOUR_MICROSOFT_CLIENT_ID"

    static func authorizationURL(for provider: CloudProvider) -> URL? {
        switch provider {
        case .dropbox:
            var c = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
            c.queryItems = [
                URLQueryItem(name: "client_id",         value: dropboxClientID),
                URLQueryItem(name: "response_type",     value: "code"),
                URLQueryItem(name: "redirect_uri",      value: "\(redirectScheme)://oauth/dropbox"),
                URLQueryItem(name: "token_access_type", value: "offline"),
            ]
            return c.url
        case .googleDrive:
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [
                URLQueryItem(name: "client_id",     value: googleClientID),
                URLQueryItem(name: "redirect_uri",  value: "\(redirectScheme)://oauth/google"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope",         value: "https://www.googleapis.com/auth/drive.readonly"),
                URLQueryItem(name: "access_type",   value: "offline"),
            ]
            return c.url
        case .oneDrive:
            var c = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
            c.queryItems = [
                URLQueryItem(name: "client_id",     value: microsoftClientID),
                URLQueryItem(name: "redirect_uri",  value: "\(redirectScheme)://oauth/onedrive"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope",         value: "Files.Read offline_access"),
            ]
            return c.url
        default:
            return nil
        }
    }

    static func exchangeCode(from callbackURL: URL, provider: CloudProvider) async throws -> String {
        guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SourceError.authenticationFailed
        }
        let (tokenURLStr, clientID, redirectURI): (String, String, String) = {
            switch provider {
            case .dropbox:
                return ("https://api.dropboxapi.com/oauth2/token",
                        dropboxClientID, "\(redirectScheme)://oauth/dropbox")
            case .googleDrive:
                return ("https://oauth2.googleapis.com/token",
                        googleClientID, "\(redirectScheme)://oauth/google")
            case .oneDrive:
                return ("https://login.microsoftonline.com/common/oauth2/v2.0/token",
                        microsoftClientID, "\(redirectScheme)://oauth/onedrive")
            default: return ("", "", "")
            }
        }()
        guard !tokenURLStr.isEmpty, let url = URL(string: tokenURLStr) else {
            throw SourceError.authenticationFailed
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=authorization_code&code=\(code)&client_id=\(clientID)&redirect_uri=\(redirectURI)"
        req.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct TokenResponse: Decodable { let access_token: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).access_token
    }
}

// MARK: - ASWebAuthenticationSession SwiftUI helper
extension ASWebAuthenticationSession {
    /// Presents a web authentication session and returns the callback URL.
    @MainActor
    static func startSession(url: URL, callbackURLScheme: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { cont in
            let coordinator = PresentationCoordinator()
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackURLScheme
            ) { callbackURL, error in
                if let error { cont.resume(throwing: error) }
                else if let cbURL = callbackURL { cont.resume(returning: cbURL) }
                else { cont.resume(throwing: SourceError.authenticationFailed) }
            }
            session.presentationContextProvider = coordinator
            session.prefersEphemeralWebBrowserSession = false
            session.start()
            // Keep coordinator alive for the duration of the session
            _ = coordinator
        }
    }
}

private final class PresentationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}

// MARK: - MusicSourceKind UI helpers
extension MusicSourceKind {
    var tintColor: Color {
        switch self {
        case .local:        .blue
        case .nas:          .indigo
        case .subsonic:     .purple
        case .webRadio:     .orange
        case .cloud:        .cyan
        case .wifiTransfer: .teal
        }
    }

    var defaultDisplayName: String {
        switch self {
        case .local:        "On This iPhone"
        case .nas:          "My NAS"
        case .subsonic:     "Navidrome"
        case .webRadio:     "Web Radio"
        case .cloud:        "Cloud Drive"
        case .wifiTransfer: "Wi-Fi Transfer"
        }
    }
}
