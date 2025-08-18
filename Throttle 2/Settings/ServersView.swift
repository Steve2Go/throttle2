import SwiftUI
import CoreData
import KeychainAccess
import AVFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - ServerEntity Extensions
extension ServerEntity {
    var sshKeyFilename: String? {
        get { sftpKey?.components(separatedBy: "/").last }
        set {
            if let newName = newValue {
                #if os(macOS)
                let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                sftpKey = sshDir.appendingPathComponent(newName).path
                #else
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let sshDir = appSupport.appendingPathComponent("SSH")
                sftpKey = sshDir.appendingPathComponent(newName).path
                #endif
            } else {
                sftpKey = nil
            }
        }
    }
    
    var sshKeyFullPath: String? {
        get { sftpKey }
        set { sftpKey = newValue }
    }
}

// MARK: - ServerRowView
struct ServerRowView: View {
    let server: ServerEntity
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: server.isLocal == true ? "desktopcomputer" : "externaldrive")
                Text((server.isDefault ? (server.name ?? "Server") + " (Default)" : server.name) ?? "Server")
                    .font(.headline)
                if server.isLocal == true {
                    Text("LOCAL")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 16)
    }
}

// MARK: - ServersListView
struct ServersListView: View {
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
        entity: ServerEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default
    ) private var servers: FetchedResults<ServerEntity>
    @State private var selection: ServerEntity?
    @State private var showingAddServer = false
    @ObservedObject var presenting: Presenting
    @ObservedObject var store: Store
    @AppStorage("useCloudKit") var useCloudKit: Bool = true
    
    // Helper computed properties for local server management
    var localServers: [ServerEntity] {
        servers.filter { $0.isLocal }
    }
    
    var canCreateLocalServer: Bool {
        localServers.count < 1
    }
    
    var localButtonTitle: String {
        return "Local"
    }
    
    var body: some View {
        VStack {
            NavigationStack {
                List(selection: $selection) {
                    ForEach(servers) { server in
                        NavigationLink(tag: server, selection: $selection) {
                            ServerEditView(server: server, store: store, onSave: { updatedServer in
                                selection = nil
                            }, onDelete: { deletedServer in
                                deleteServer(deletedServer)
                            })
                        } label: {
                            ServerRowView(server: server)
                        }
                    }
                }.onAppear(){
                    selection = nil
                }
                .navigationTitle("Servers")
                .sheet(isPresented: $showingAddServer) {
                    NavigationStack {
                        ServerEditView(server: nil, onSave: { newServer in
                            showingAddServer = false
                        }).environment(\.managedObjectContext, viewContext)
                    }
                    #if os(macOS)
                    .padding(20)
                    #endif
                }
                .toolbar {
                    Button(action: {
                        showingAddServer = true
                    }) {
                        Label("Add Server", systemImage: "plus")
                    }
                    
                    // Add Local Server button (Apple Silicon only)
                    #if os(macOS)
                    if ProcessInfo.isAppleSilicon && canCreateLocalServer {
                        Button(action: {
                            createLocalServer()
                        }) {
                            Label(localButtonTitle, systemImage: "desktopcomputer")
                        }
                    }
                    #endif
                    
                    if selection == nil {
                        Button(action: {
                            presenting.activeSheet = nil
                        }) {
                            Label("Close", systemImage: "xmark")
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .padding(20)
        #endif
    }
    
    private func createLocalServer() {
        // Prevent creation if limit is reached
        guard canCreateLocalServer else {
            print("Cannot create local server: limit of 1 reached")
            return
        }
        
        withAnimation {
            let newServer = ServerEntity(context: viewContext)
            newServer.id = UUID()
            // Name based on current count
            let currentCount = localServers.count
            newServer.name = currentCount == 0 ? "Local Server" : "Local Server \(currentCount + 1)"
            newServer.isDefault = servers.isEmpty // Make default if no other servers
            newServer.isLocal = true
            
            // Set dummy values for local server
            newServer.url = "127.0.0.1"
            newServer.port = 9091
            newServer.rpc = "/transmission/rpc"
            newServer.user = ""
            newServer.pathServer = "/"
            newServer.pathFilesystem = "/"
            newServer.sftpBrowse = false
            newServer.sftpRpc = false
            newServer.protoHttps = false
            
            // Set local server specific defaults
            newServer.localPort = 9091
            newServer.localDaemonEnabled = false
            newServer.localStartOnLogin = false
            newServer.localRemoteAccess = false
            newServer.localRemoteUsername = "throttle"
            newServer.localRemotePassword = generateRandomPassword()
            newServer.localSSHKeyGenerated = false
            
            do {
                try viewContext.save()
                print("Local server created successfully")
                // Auto-select the new local server
                selection = newServer
            } catch {
                print("Failed to create local server: \(error)")
            }
        }
    }
    
    private func generateRandomPassword() -> String {
        let charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<12).map { _ in charset.randomElement()! })
    }

    private func deleteServer(_ server: ServerEntity) {
        withAnimation {
            let keychain = useCloudKit ? Keychain(service: "srgim.throttle2").synchronizable(true) : Keychain(service: "srgim.throttle2").synchronizable(false)
            keychain["password" + (server.name ?? "")] = nil
            keychain["httpPassword" + (server.name ?? "")] = nil
            keychain["sftpPassword" + (server.name ?? "")] = nil
            keychain["sftpKey" + (server.name ?? "")] = nil
            
            // Also clean up any stored SSH keys
            if let keyPath = server.sshKeyFullPath,
               FileManager.default.fileExists(atPath: keyPath) {
                try? FileManager.default.removeItem(atPath: keyPath)
            }
            
            viewContext.delete(server)
            if selection == server {
                selection = nil
            }
            do {
                try viewContext.save()
                print("Server deleted successfully")
            } catch {
                print("Failed to delete server: \(error)")
            }
        }
    }
}

// MARK: - ServerEditView
struct ServerEditView: View {
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
        entity: ServerEntity.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default
    ) var allServers: FetchedResults<ServerEntity>
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: Store
    
    @State var server: ServerEntity?
    var onSave: ((ServerEntity) -> Void)?
    var onDelete: ((ServerEntity) -> Void)?
    
    // Torrent section
    @State private var name: String
    @State private var isDefault: Bool
    @State private var url: String
    @State private var port: String
    @State private var rpc: String
    @State private var user: String
    @State private var password: String
    
    // SFTP section
    @State private var sftpHost: String
    @State private var sftpPort: String
    @State private var sftpUser: String
    @State private var sftpPassword: String
    @State private var sftpPhrase: String
    @State private var sftpBrowse: Bool
    @State private var sftpRpc: Bool
    @State private var pathServer: String
    @State private var pathFilesystem: String
    @State private var fsBrowse: Bool
    @State private var protHttps: Bool
    @State private var fsPath: String = ""
    @State private var fsThumb: Bool
    @State private var ffThumb: Bool = true
    @State private var thumbMax: String = "4"
    @State private var hasPython: Bool
    @State private var videoDisabled : Bool
    
    // Updated SFTP Authentication
    @State private var sftpUsesKey: Bool
    @State private var sftpKey: String
    @State private var showingSFTPKeyImporter: Bool = false
    @Environment(\.openURL) private var openURL
    @State var installerView = false
    @AppStorage("useCloudKit") var useCloudKit: Bool = true
    
    // Local Server settings
    @State private var isLocal: Bool
    @State private var localPort: String
    @State private var localDaemonEnabled: Bool
    @State private var localStartOnLogin: Bool
    @State private var localRemoteAccess: Bool
    @State private var localRemoteUsername: String
    @State private var localRemotePassword: String
    @State private var localSSHKeyGenerated: Bool

    
    @State private var showingKeyErrorAlert = false
    @State private var keyErrorMessage = ""

    #if os(macOS)
    @State private var installerSheetPresented = false
    #endif

    let keychain = Keychain(service: "srgim.throttle2")
        .synchronizable(true)
    
    init(server: ServerEntity?, store: Store = .init(), onSave: ((ServerEntity) -> Void)? = nil, onDelete: ((ServerEntity) -> Void)? = nil) {
        self.server = server
        self.onSave = onSave
        self.onDelete = onDelete
        self.store = store
        
        _name = State(initialValue: server?.name ?? "")
        _isDefault = State(initialValue: server?.isDefault ?? false)
        _url = State(initialValue: server?.url ?? "")
        _port = State(initialValue: String(server?.port ?? 9091))
        _rpc = State(initialValue: server?.rpc ?? "/transmission/rpc")
        _user = State(initialValue: server?.user ?? "")
        _password = State(initialValue: keychain["password" + (server?.name ?? "")] ?? "")
        
        _sftpBrowse = State(initialValue: server?.sftpBrowse ?? false)
        _sftpRpc = State(initialValue: server?.sftpRpc ?? false)
        _sftpHost = State(initialValue: server?.sftpHost ?? "")
        _sftpPort = State(initialValue: String(server?.sftpPort ?? 22))
        _sftpUser = State(initialValue: server?.sftpUser ?? "")
        _sftpPassword = State(initialValue: keychain["sftpPassword" + (server?.name ?? "")] ?? "")
        _pathServer = State(initialValue: server?.pathServer ?? "")
        _pathFilesystem = State(initialValue: server?.pathFilesystem ?? "")
        _fsPath = State(initialValue: server?.fsPath ?? "")
        _fsThumb = State(initialValue: server?.fsThumb ?? false)
        _fsBrowse = State(initialValue: server?.fsBrowse ?? false)
        _protHttps = State(initialValue: server?.protoHttps ?? false)
        _ffThumb = State(initialValue: server?.ffThumb ?? false)
        // Initialize SFTP authentication states
        _sftpUsesKey = State(initialValue: server?.sftpUsesKey ?? false)
        ///Leaving a spare connection for the video player 
        _thumbMax = State(initialValue: String((Int(server?.thumbMax ?? 8) + 1)))
        _sftpKey = State(initialValue: keychain["sftpKey" + (server?.name ?? "")] ?? "")
        _hasPython = State(initialValue: server?.hasPython ?? true)
        _videoDisabled = State(initialValue: server?.videoDisabled ?? false)
        _sftpPhrase = State(initialValue: keychain["sftpPhrase" + (server?.name ?? "")] ?? "")
        
        // Initialize local server states
        _isLocal = State(initialValue: server?.isLocal ?? false)
        _localPort = State(initialValue: String(server?.localPort ?? 9091))
        _localDaemonEnabled = State(initialValue: server?.localDaemonEnabled ?? false)
        _localStartOnLogin = State(initialValue: server?.localStartOnLogin ?? false)
        _localRemoteAccess = State(initialValue: server?.localRemoteAccess ?? false)
        _localRemoteUsername = State(initialValue: server?.localRemoteUsername ?? "throttle")
        _localRemotePassword = State(initialValue: server?.localRemotePassword ?? "")
        _localSSHKeyGenerated = State(initialValue: server?.localSSHKeyGenerated ?? false)

    }
    
    private enum KeyError: Error {
        case invalidKeyFormat
        case securityAccessDenied

    }
    
    var body: some View {
        #if os(macOS)
        let fileManager = FileManager.default
        let fusetIsInstalled = fileManager.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib")
        let sshfsIsInstalled = fileManager.fileExists(atPath: "/usr/local/bin/sshfs")
        #endif
        NavigationStack {
            Form {
                // **Server Type Section**
                Section(header: Text(isLocal ? "Local Transmission Server" : "Transmission Connection")) {
                    #if os(iOS)
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField(isLocal ? "Local server name" : "Server name", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    if isLocal {
                        // Local server specific settings
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("Port number", text: $localPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        
                        Toggle("Start daemon on login", isOn: $localStartOnLogin)
                        Toggle("Enable remote access", isOn: $localRemoteAccess)
                        
                        if localRemoteAccess {
                            HStack {
                                Text("Username")
                                Spacer()
                                TextField("Username", text: $localRemoteUsername)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(maxWidth: 120)
                            }
                            
                            HStack {
                                Text("Password")
                                Spacer()
                                SecureField("Password", text: $localRemotePassword)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(maxWidth: 120)
                            }
                            
                            HStack {
                                Text("SSH Key")
                                Spacer()
                                Text(localSSHKeyGenerated ? "Generated" : "Not Generated")
                                    .foregroundColor(localSSHKeyGenerated ? .green : .orange)
                            }
                        }
                        
                    } else {
                        // Regular server settings
                        Toggle("RPC Over SSH Tunnel", isOn: $sftpRpc)
                            .onChange(of: sftpRpc){
                                if sftpRpc {
                                    sftpBrowse = true
                                }
                            }
                        if !sftpRpc {
                            Toggle("Server Uses SSL (https)", isOn: $protHttps)
                            HStack {
                                Text("Server")
                                Spacer()
                                TextField("Server address", text: $url)
                                    .multilineTextAlignment(.trailing)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                            }
                        } else {
                            Text("SSL not available when tunneling, tunnel should be direct to the Transmission server")
                                .font(.caption)
                        }
                    }
                    #else
                    TextField(isLocal ? "Local server name" : "Server name", text: $name)
                    
                    if isLocal {
                        // Local server specific settings (macOS)
                        TextField("Port", text: $localPort)
                        Toggle("Start daemon on login", isOn: $localStartOnLogin)
                        Toggle("Enable remote access", isOn: $localRemoteAccess)
                        
                        if localRemoteAccess {
                            TextField("Username", text: $localRemoteUsername)
                            SecureField("Password", text: $localRemotePassword)
                            
                            HStack {
                                Text("SSH Key Status:")
                                Spacer()
                                Text(localSSHKeyGenerated ? "Generated" : "Not Generated")
                                    .foregroundColor(localSSHKeyGenerated ? .green : .orange)
                                if !localSSHKeyGenerated {
                                    Button("Generate") {
                                        // TODO: Generate SSH key
                                        localSSHKeyGenerated = true
                                    }
                                }
                            }
                        }
                        
                    } else {
                        // Regular server settings (macOS)
                        Toggle("RPC Over SSH Tunnel", isOn: $sftpRpc)
                            .onChange(of: sftpRpc){
                                if sftpRpc {
                                    sftpBrowse = true
                                }
                            }
                        if !sftpRpc {
                            Toggle("Server Uses SSL (https)", isOn: $protHttps)
                            TextField("Server", text: $url)
                        } else {
                            Text("SSL not available when tunneling, tunnel should be direct to the Transmission server").font(.caption)
                        }
                    }
                    #endif
                    
                    // Common settings for both local and remote servers
                    if !isLocal {
                        #if os(iOS)
                        HStack {
                            Text("RPC Port")
                            Spacer()
                            TextField("Port number", text: $port)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        HStack {
                            Text("RPC Path")
                            Spacer()
                            TextField("Path", text: $rpc)
                                .multilineTextAlignment(.trailing)
                        }
                        #else
                        TextField("RPC Port", text: $port)
                        TextField("RPC Path", text: $rpc)
                        #endif
                    }
                    
                    Toggle("Default Server", isOn: $isDefault)
                    
                    Toggle("Default Server", isOn: $isDefault)
                    
                    // Authentication section - only for remote servers
                    if !isLocal {
                        #if os(iOS)
                        HStack {
                            Text("Username")
                            Spacer()
                            TextField("Username", text: $user)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                        }
                        HStack {
                            Text("Password")
                            Spacer()
                            SecureField("Password", text: $password)
                                .multilineTextAlignment(.trailing)
                        }
                        #else
                        TextField("Username", text: $user)
                        SecureField("Password", text: $password)
                        #endif
                    }
                }
                
                // Only show SSH/SFTP sections for non-local servers
                if !isLocal {
                    #if os(macOS)
                    Divider()
                    #endif
                    
                    // **SFTP Authentication & Path Mapping**
                    Section(header: Text("SSH Connection")) {
                    #if os(macOS)
                    Toggle("SSH Path Mapping", isOn: $sftpBrowse)
                        .disabled(!fusetIsInstalled || !sshfsIsInstalled)
                    #else
                    Toggle("SSH Path Mapping", isOn: $sftpBrowse)
                    #endif
                    
                    if sftpBrowse || sftpRpc {
                        #if os(iOS)
                        HStack {
                            Text("SSH Host")
                            Spacer()
                            TextField("Host address", text: $sftpHost)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                        }
                        HStack {
                            Text("SSH Port")
                            Spacer()
                            TextField("Port number", text: $sftpPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        HStack {
                            Text("Server Path")
                            Spacer()
                            TextField("Path on server", text: $pathServer)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Username")
                            Spacer()
                            TextField("SFTP username", text: $sftpUser)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                        }
                        Toggle("Use SSH Key", isOn: $sftpUsesKey)

                        
                        if sftpUsesKey {
                            HStack {
                                Text("SSH Key")
                                Spacer()
                                Text(sftpKey.isEmpty ? "No key selected" : "Key selected")
                                    .foregroundColor(.secondary)
                                Button("Select") {
                                    showingSFTPKeyImporter = true
                                }
                                .buttonStyle(.borderless)
                            }
                            HStack {
                                Text("Key Passphrase (optional)")
                                Spacer()
                                SecureField("Key Passphrase", text: $sftpPhrase)
                                    .multilineTextAlignment(.trailing)
                            }

                            //Text("Used for video operation. Only used over a tunnel secured by Key Authentication").font(.caption)
                           //Toggle("Do not connect to SFTP for video streaming using a local password", isOn: $videoDisabled)
                        } else {
                            HStack {
                                Text("Password")
                                Spacer()
                                SecureField("SFTP password", text: $sftpPassword)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        
                        HStack {
                            Text("Max Connections")
                            Spacer()
                            TextField("Max SSH connections", text: $thumbMax)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        
                        #else
                        
                        TextField("SFTP Host", text: $sftpHost)
                        TextField("SFTP Port", text: $sftpPort)
                        TextField("Server Path", text: $pathServer)
                        TextField("Username", text: $sftpUser)
                        Toggle("Use SFTP Key", isOn: $sftpUsesKey)
                        if sftpUsesKey {
                            HStack {
                                Text(sftpKey.isEmpty ? "No SFTP key selected" : "SFTP key selected")
                                Spacer()
                                Button("Select Key File") {
                                    showingSFTPKeyImporter = true
                                }
                            }
                            HStack {
                                SecureField("Key Passphrase", text: $sftpPhrase)
                                    .multilineTextAlignment(.trailing)
                            }
                            
                        } else {
                            SecureField("Password", text: $sftpPassword)
                        }
                        //Text("Torrent creation depends on Transmission-create").font(.caption)
                        #endif
                    }
                }
                
                #if os(macOS)
                if sftpBrowse == false {
                    Divider()
                    Section(header: Text("Traditional Path Mapping")) {
                        Toggle("Local Mapping", isOn: $fsBrowse)
                        if fsBrowse {
                            TextField("Server Path", text: $pathServer)
                            TextField("Local Path", text: $pathFilesystem)
                            Toggle("Local Mapping", isOn: $fsBrowse)
                            Toggle("Thumbnails", isOn: $fsThumb)
                        }
                    }
                }
                #endif
                } // End of !isLocal conditional
            }
            .fileImporter(
                isPresented: $showingSFTPKeyImporter,
                allowedContentTypes: [.item],
                onCompletion: { result in
                    switch result {
                    case .success(let url):
                        _ = url.startAccessingSecurityScopedResource()
                        handleSSHKey(keyFileURL: url)
                    case .failure(let error):
                        print("File selection error: \(error)")
                    }
                }
            )
            #if os(macOS)
            .sheet(isPresented: $installerSheetPresented) {
                InstallerView()
                    .frame(width: 500, height: 500)
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
#if os(macOS)
                    if sftpBrowse && (!fusetIsInstalled || !sshfsIsInstalled) {
                        Button("Install Required Components") {
                            installerSheetPresented = true
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Save") {
                            saveServer()
                        }
                        .disabled(name.isEmpty || (url.isEmpty && !sftpRpc))
                    }
#else
                    Button("Save") {
                        saveServer()
                    }
                    .disabled(name.isEmpty || (url.isEmpty && !sftpRpc))
#endif
                }
                if server != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            deleteServer(server!)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .alert("SSH Key Error", isPresented: $showingKeyErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(keyErrorMessage)
        }
    }
    

    // MARK: - SSH Key Handling
    private func handleSSHKey(keyFileURL: URL) {
        do {

            // Read the key content
            
            let keyContent = try String(contentsOf: keyFileURL)
            
            // Store the full key content in the keychain with server name
            keychain["sftpKey" + name] = keyContent
            
            // Store the passphrase if provided
            if !sftpPhrase.isEmpty {
                keychain["sftpPhrase" + name] = sftpPhrase
            }
            
            // Set a flag indicating we're using a key - keep a reference to the file
            // name but not the full path (since the actual content is in keychain)
            let keyFileName = keyFileURL.lastPathComponent
            //sftpKey = "key:" + keyFileName
            sftpUsesKey = true
            sftpKey = keyFileName
            
            print("SSH key saved to keychain: \(keyFileName)")

        } catch {
            print("Failed to process SSH key: \(error)")
            keyErrorMessage = "Failed to process the SSH key: \(error.localizedDescription)"
            showingKeyErrorAlert = true
        }
    }


    func saveToKeychain() {
        keychain["password" + name] = password
        
        if sftpUsesKey {
            if !sftpPhrase.isEmpty {
                keychain["sftpPhrase" + name] = sftpPhrase
            }
            
            if !sftpPassword.isEmpty {
                keychain["sftpPassword" + name] = sftpPassword
            }
        } else {
            keychain["sftpPassword" + name] = sftpPassword
        }
    }
    
    

    
    func isWindowsFilePath(_ path: String) -> Bool {
        return path.contains(":") || path.contains("\\")
    }
    
    func saveServer() {
        withAnimation {
            // Update default status if needed
            if isDefault {
                for server in allServers where server.isDefault {
                    server.isDefault = false
                }
            }
            // Make sure we have at least one default server
            if !allServers.contains(where: { $0.isDefault }) {
                isDefault = true
            }
            // remove trailing slash
            if pathServer.hasSuffix("/") {
                pathServer.removeLast()
            }
            if pathFilesystem.hasSuffix("/") {
                pathFilesystem.removeLast()
            }
            
            if !pathFilesystem.hasPrefix("/") {
                pathFilesystem = "/" + pathFilesystem
            }
            //ensure starting slash
            if !isWindowsFilePath(pathServer) {
                if !pathServer.hasPrefix("/") {
                    pathServer = "/" + pathServer
                }
            }
            
            if let existingServer = server {
                // Update existing server
                existingServer.name = name
                existingServer.url = url
                existingServer.port = Int32(Int(port) ?? 443)
                existingServer.rpc = rpc
                existingServer.user = user
                existingServer.isDefault = isDefault
                existingServer.sftpBrowse = sftpBrowse
                existingServer.sftpRpc = sftpRpc
                existingServer.sftpHost = sftpHost
                existingServer.sftpPort = Int32(Int(sftpPort) ?? 22)
                existingServer.sftpUser = sftpUser
                existingServer.pathServer = pathServer
                existingServer.pathFilesystem = pathFilesystem
                existingServer.fsPath = fsPath
                existingServer.fsThumb = fsThumb
                existingServer.ffThumb = ffThumb
                existingServer.fsBrowse = fsBrowse
                existingServer.sftpUsesKey = sftpUsesKey
                existingServer.protoHttps = protHttps
                existingServer.thumbMax = Int32(Int(thumbMax)! - 1)
                existingServer.hasPython = hasPython
                existingServer.videoDisabled = videoDisabled
                
                // Update local server properties
                existingServer.isLocal = isLocal
                existingServer.localPort = Int32(Int(localPort) ?? 9091)
                existingServer.localDaemonEnabled = localDaemonEnabled
                existingServer.localStartOnLogin = localStartOnLogin
                existingServer.localRemoteAccess = localRemoteAccess
                existingServer.localRemoteUsername = localRemoteUsername
                existingServer.localRemotePassword = localRemotePassword
                existingServer.localSSHKeyGenerated = localSSHKeyGenerated
                
                saveToKeychain()
                store.selection = nil
                store.selection = existingServer
                
                onSave?(existingServer)
            } else {
                // Create new server
                let newServer = ServerEntity(context: viewContext)
                newServer.id = UUID()
                newServer.name = name
                newServer.isDefault = isDefault
                newServer.url = url
                newServer.port = Int32(Int(port) ?? 443)
                newServer.rpc = rpc
                newServer.user = user
                newServer.sftpRpc = sftpRpc
                newServer.sftpBrowse = sftpBrowse
                newServer.protoHttps = protHttps
                newServer.sftpHost = sftpHost
                newServer.sftpPort = Int32(Int(sftpPort) ?? 22)
                newServer.sftpUser = sftpUser
                newServer.pathServer = pathServer
                newServer.pathFilesystem = pathFilesystem
                newServer.fsPath = fsPath
                newServer.fsThumb = fsThumb
                newServer.ffThumb = ffThumb
                newServer.fsBrowse = fsBrowse
                newServer.sftpUsesKey = sftpUsesKey
                newServer.thumbMax = Int32(Int(thumbMax)! - 1)
                newServer.hasPython = hasPython
                newServer.videoDisabled = videoDisabled
                
                // Set local server properties
                newServer.isLocal = isLocal
                newServer.localPort = Int32(Int(localPort) ?? 9091)
                newServer.localDaemonEnabled = localDaemonEnabled
                newServer.localStartOnLogin = localStartOnLogin
                newServer.localRemoteAccess = localRemoteAccess
                newServer.localRemoteUsername = localRemoteUsername
                newServer.localRemotePassword = localRemotePassword
                newServer.localSSHKeyGenerated = localSSHKeyGenerated
                
                saveToKeychain()
                //workaround to freshen server settings
                store.selection = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    store.selection = newServer
                }
                onSave?(newServer)
            }
            
            
            // Save context
            do {
                try viewContext.save()
                print("Server saved successfully")
            } catch {
                print("Failed to save server: \(error)")
            }
            #if os(macOS)
            do{
                let serverArray = Array(try viewContext.fetch(ServerEntity.fetchRequest()))
                ServerMountManager.shared.unmountAllServers()
                if !serverArray.isEmpty {
                }
            } catch {
                ServerMountManager.shared.unmountAllServers()
            }
            #endif
            
            DispatchQueue.main.async {
                dismiss()
            }
        }
    }
    
    func savePrivateKey(_ keyContent: String, for server: ServerEntity) throws {
        try keychain.set(keyContent, key: "sftpKey" + (server.name ?? ""))

    }

    func saveKeyPassphrase(_ passphrase: String, for server: ServerEntity) throws {
        try keychain.set(passphrase, key: "sftpPhrase" + (server.name ?? ""))
    }
    
    
    
    private func deleteServer(_ server: ServerEntity) {
        withAnimation {
            let keychain = Keychain(service: "srgim.throttle2")
                .synchronizable(useCloudKit)
            
            // Clear standard credentials

            keychain["password" + (server.name ?? "")] = nil
            keychain["httpPassword" + (server.name ?? "")] = nil
            keychain["sftpPassword" + (server.name ?? "")] = nil
            
            // Clean up SSH keys using SSHKeyManager
            SSHKeyManager.shared.removeKeysFor(serverName: server.name ?? "")
            
            // Delete the server from Core Data
            viewContext.delete(server)
            if store.selection == server {
                store.selection = nil
            }
            
            do {
                try viewContext.save()
                print("Server deleted successfully")
            } catch {
                print("Failed to delete server: \(error)")
            }
            do {
                let serverArray = Array(try viewContext.fetch(ServerEntity.fetchRequest()))
#if os(macOS)
                ServerMountManager.shared.unmountAllServers()
                #endif
                    if !serverArray.isEmpty {
                        #if os(macOS)
                        ServerMountManager.shared.mountAllServers(serverArray)
                        #endif
                        store.selection = serverArray.first ?? nil
                }
            } catch {
                store.selection = nil
            }
            
            
            DispatchQueue.main.async {
                dismiss()
            }
        }
    
    }
}
