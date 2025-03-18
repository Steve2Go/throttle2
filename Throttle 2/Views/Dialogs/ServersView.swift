import SwiftUI
import KeychainAccess
import SimpleToast
import CoreData


struct ServerRowView: View {
    let server: Servers
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((server.isDefault ? "\(server.name) (Default)" : server.name) ?? "Server")
                .font(.headline)
            
            VStack(alignment: .leading) {
                Text("🌐 Torrent: \(server.url)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
//                if let httpURL = server.pathHttp {
//                    Text("🔗 HTTP: \(httpURL)")
//                        .font(.subheadline)
//                        .foregroundColor(.secondary)
//                }
                
                if let sftpHost = server.sftpHost {
                    Text("📂 SFTP: \(sftpHost) on Port \(Int(server.sftpPort))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 16) // Added horizontal padding
        .frame(maxWidth: .infinity, alignment: .topLeading) // Aligns the content to the top
    }
}

struct ServersListView: View {
    @Environment(\.managedObjectContext) var viewContext
    @State private var selection: Servers?
    @State private var showingAddServer = false
    @ObservedObject var presenting: Presenting
    @Binding var activeSheet: ActiveSheet?
    @ObservedObject var store: Store
    @FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Servers.name, ascending: true)],
            animation: .default)
        private var servers: FetchedResults<Servers>
    
    var body: some View {
//        VStack {
//            #if os(macOS)
//            HStack {
//                MacCloseButton {
//                    activeSheet = nil
//                }.padding([.top, .leading], 15)
//                Spacer()
//                Text("Server Management")
//                    .font(.headline)
//                    .foregroundColor(.primary)
//                    .padding(.top, 15)
//                Spacer()
//            }
//            #endif
//            NavigationStack {
//                List(selection: $selection) {
//                    ForEach(servers) { server in
//                        NavigationLink(tag: server, selection: $selection) {
//                            ServerEditView(server: server, onSave: { updatedServer in
//                                selection = nil
//                            }, onDelete: { deletedServer in
//                                deleteServer(deletedServer)
//                            })
//                        } label: {
//                            ServerRowView(server: server)
//                        }
//                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
//                            Button(role: .destructive) {
//                                deleteServer(server)
//                            } label: {
//                                Label("Delete", systemImage: "trash")
//                            }
//                        }
//                    }
//                }
//                .navigationTitle("Servers")
//                .sheet(isPresented: $showingAddServer) {
//                    NavigationStack {
//                        ServerEditView(server: nil, onSave: { newServer in
//                            showingAddServer = false
//                        })
//                    }
//                }
//                .toolbar {
//                    Button(action: {
//                        showingAddServer = true
//                    }) {
//                        Label("Add Server", systemImage: "plus")
//                    }
//                }
//            }
      //  }
        Text("placeholder")
    }
    
    private func deleteServer(_ server: Servers) {
        withAnimation {
            let keychain = Keychain(service: "srgim.throttle2")
            keychain["password" + server.name!] = nil
            keychain["httpPassword" + server.name!] = nil
            keychain["sftpPassword" + server.name!] = nil
            
            let context = DataManager.shared.viewContext
            deleteServer(server)
            if selection == server {
                selection = nil
            }
        }
    }
}

struct ServerEditView: View {
    @Environment(\.managedObjectContext) var viewContext
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var store: Store
    @FetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \Servers.name, ascending: true)],
            animation: .default)
        private var allServers: FetchedResults<Servers>
    // Optional server passed in; if nil, we're creating a new one.
    var server: Servers?

    // Provide default values for your state properties.
    @State private var name: String = ""
    @State private var isDefault: Bool = false
    @State private var url: String = ""
    @State private var port: String = "443"
    @State private var rpc: String = "/transmission/rpc"
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var pathServer: String = ""
    @State private var pathFilesystem: String = ""
    @State private var sftpHost: String = ""
    @State private var sftpPort: String = "22"
    @State private var sftpUser: String = ""
    @State private var sftpPassword: String = ""
    @State private var sftpBrowse: Bool = false
    @State private var fsBrowse: Bool = false
    @State private var fsPath: String = ""
    @State private var sftpPath: String = ""
    @State private var fsThumb: Bool = false

    // Keychain remains as before.
    let keychain = Keychain(service: "srgim.throttle2")
        .synchronizable(true)

    var body: some View {
        NavigationStack {
                    Form {
                        // **Torrent**
                        Section(header: Text("Torrent Server")) {
                            TextField("Name", text: $name)
                            TextField("URL", text: $url)
                            TextField("Port", text: $port)
                            TextField("RPC Path", text: $rpc)
                            Toggle("Default Server", isOn: $isDefault)
                            TextField("Username", text: $user)
                            SecureField("Password", text: $password)
                        }
                        // **SFTP**
                        Section(header: Text("SFTP path Mapping")) {
                            Toggle("SFTP Path Mapping", isOn: $sftpBrowse)
                            if sftpBrowse {
                                TextField("SFTP Host", text: $sftpHost)
                                TextField("SFTP Port", text: $sftpPort)
                                TextField("Server Path", text: $pathServer)
                                TextField("Username", text: $sftpUser)
                                SecureField("Password", text: $sftpPassword)
                            }
                        }
                        #if os(macOS)
                        if sftpBrowse == false {
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
                    }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveServer()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
                if server != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            deleteServer(server!, store: store)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } else {
                    ToolbarItem(placement: .automatic) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }.onAppear {
                // If a server was passed in, update state properties.
                if let server = server {
                    name = server.name ?? ""
                    isDefault = server.isDefault
                    url = server.url ?? ""
                    port = String(Int(server.port))
                    rpc = server.rpc ?? "/transmission/rpc"
                    user = server.user ?? ""
                    // You might want to fetch passwords from keychain here.
                    password = keychain["password" + (server.name ?? "")] ?? ""
                    sftpBrowse = server.sftpBrowse
                    sftpHost = server.sftpHost ?? ""
                    sftpPort = String(Int(server.sftpPort))
                    sftpUser = server.sftpUser ?? ""
                    sftpPassword = keychain["sftpPassword" + (server.name ?? "")] ?? ""
                    pathServer = server.pathServer ?? ""
                    pathFilesystem = server.pathFilesystem ?? ""
                    fsPath = server.fsPath ?? ""
                    fsThumb = server.fsThumb
                    fsBrowse = server.fsBrowse
                }
            }
        }
    }

    private func saveServer() {
        withAnimation {
            if isDefault {
                for server in allServers where server.isDefault {
                    server.isDefault = false
                }
            }
            if !allServers.contains(where: { $0.isDefault }) {
                isDefault = true
            }
            let context = DataManager.shared.viewContext
            if let existingServer = server {
                existingServer.name = name
                existingServer.url = url
                existingServer.port = Int32(Int(port) ?? 443)
                existingServer.rpc = rpc
                existingServer.user = user
                existingServer.isDefault = isDefault
                existingServer.sftpBrowse = sftpBrowse
                existingServer.sftpHost = sftpHost
                existingServer.sftpPort = Int32(Int(sftpPort) ?? 22)
                existingServer.sftpUser = sftpUser
                existingServer.pathServer = pathServer
                existingServer.pathFilesystem = pathFilesystem
                existingServer.fsPath = fsPath
                existingServer.fsThumb = fsThumb
                existingServer.fsBrowse = fsBrowse
                saveToKeychain()
                //onSave?(existingServer)
                DataManager.shared.saveContext()
            } else {
                //let newServer = Servers(name: name)
                let newServer = Servers(context: context)
                newServer.isDefault = isDefault
                newServer.url = url
                newServer.port = Int32(Int(port) ?? 443)
                newServer.sftpBrowse = sftpBrowse
                newServer.sftpHost = sftpHost
                newServer.sftpPort = Int32(Int(sftpPort) ?? 22)
                newServer.sftpUser = sftpUser
                newServer.pathServer = pathServer
                newServer.pathFilesystem = pathFilesystem
                newServer.fsPath = fsPath
                newServer.fsThumb = fsThumb
                newServer.fsBrowse = fsBrowse
                DataManager.shared.saveContext()
                //modelContext.insert(newServer)
                saveToKeychain()
                //onSave?(newServer)
                DataManager.shared.saveContext()
            }

            DispatchQueue.main.async {
                dismiss()
            }
        }
    }

    private func saveToKeychain() {
        keychain["password" + name] = password
        keychain["sftpPassword" + name] = sftpPassword
    }

    private func deleteServer(_ server: Servers, store: Store) {
        withAnimation {
            let keychain = Keychain(service: "srgim.throttle2")
            keychain["password" + server.name!] = nil
            keychain["httpPassword" + server.name!] = nil
            keychain["sftpPassword" + server.name!] = nil

            let context = DataManager.shared.viewContext
            context.delete(server)
            do {
                try context.save()
            } catch {
                print("❌ Failed to save context after deletion: \(error)")
            }
            if store.selection == server {
                store.selection = nil
            }
        }
    }
}
