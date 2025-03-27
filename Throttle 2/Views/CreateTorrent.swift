//#if os(macOS)
import SwiftUI
import KeychainAccess
import CoreData
import NIOSSH
import NIOCore
import mft

struct CreateTorrent: View {
    @ObservedObject var store: Store
    @ObservedObject var presenting: Presenting
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default)
    var servers: FetchedResults<ServerEntity>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    // State variables remain the same
    @State var filePath = ""
    @State var outputPath = ""
    @State var uploadPath = ""
    @State var tracker = ""
    @State var trackers = ""
    @State var isRemote = false
    @State var isCreated = false
    @State var selecting = false
    @State var commandOutput = ""
    @State var isProcessing = false
    @State var localPath = ""
    @State var isDownloading = false
    @State var isError = false
    @AppStorage("createdOnce") var createdOnce = false
    
    var body: some View {
        NavigationStack {
            Form {
                if !isProcessing {
                    Section {
                        HStack {
                            TextField("Source file or folder", text: $filePath)
                            Button(action: { selecting.toggle() }) {
                                Image(systemName: "folder")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    } header: {
                        Text("Source")
                    }
                    
                    Section {
                        TextField("Enter tracker URLs", text: $tracker)
                            .textFieldStyle(.automatic)
#if os(iOS)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
#endif
                    } header: {
                        Text("Trackers")
                    } footer: {
                        Text("Separate multiple trackers with commas")
                    }
                    
                    Section {
                        Picker("Server", selection: $store.selection) {
                            ForEach(servers) { server in
                                Text(server.name ?? "Unknown").tag(server as ServerEntity?)
                            }
                        }
                    }
                }
                
                
                if isProcessing {
                    if !isCreated && !isError {
                        ProgressView()
                           
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(commandOutput)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } header: {
                        Text("Progress")
                    }
                }
                #if os(macOS)
                Spacer()
                #endif
            }
            .navigationTitle("Create Torrent")
            .sheet(isPresented: $selecting) {
    #if os(iOS)
                NavigationView {
                    FileBrowserView(
                        currentPath: store.selection?.pathServer ?? "",
                        basePath: store.selection?.pathServer ?? "",
                        server: store.selection,
                        onFolderSelected: { folderPath in
                            filePath = folderPath
                            selecting = false
                        },
                        selectFiles: true
                    )
                    .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Cancel") {
                                    selecting = false
                                }
                            }
                        }
                }.presentationDetents([.large])
                  
                
    #else
                FileBrowserView(
                    currentPath: store.selection?.pathServer ?? "",
                    basePath: store.selection?.pathServer ?? "",
                    server: store.selection,
                    onFolderSelected: { folderPath in
                        filePath = folderPath
                        selecting = false
                    },
                    selectFiles: true
                ).frame(width: 600, height: 600)
    #endif
            
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Text(isCreated ? "Done" : "Cancel")
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    if !isCreated {
                        Button {
                            Task {
                                try await createTorrent()
                            }
                        } label: {
                            Text("Build Torrent")
                        }
                        .disabled(filePath.isEmpty || isProcessing)
                    } else {
                        Button {
                            store.addPath = (filePath as NSString).deletingLastPathComponent
                            openFile(path: localPath)
                        } label: {
                            Text("Start Seeding")
                        }
                        .disabled(localPath.isEmpty)
                    }
                }
                
            }
        }
        
        .onAppear {
            #if os(iOS)
            isRemote = true
            #endif
        }
    }
    func openFile(path: String) {
            store.addPath = (filePath as NSString).deletingLastPathComponent
                
            #if os(macOS)
        Task{
            dismiss()
            try await Task.sleep(for: .milliseconds(500))
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
            #else
            if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let filename = URL(string: path)?.lastPathComponent {
                let fileURL = documentsURL.appendingPathComponent(filename)
                
                // First dismiss this view
                dismiss()
                
                // Then trigger the URL handling after a short delay
                Task {
                    try await Task.sleep(for: .milliseconds(500))
                    store.selectedFile = fileURL
                    store.selectedFile?.startAccessingSecurityScopedResource()
                    presenting.activeSheet = "adding"
                }
            }
            #endif
        }
    func createTorrent() async throws {
        isProcessing = true
        isError = false
        commandOutput = "Connecting to server..."
        
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let username = store.selection?.sftpUser,
              let password = keychain["sftpPassword" + (store.selection?.name ?? "")],
              let hostname = store.selection?.sftpHost else {
            return
        }
        
        // Create SFTP connection
        let sftp = MFTSftpConnection(hostname: hostname,
                                    port: Int(store.selection!.sftpPort),
                                    username: username,
                                    password: password)
        
        try sftp.connect()
        try sftp.authenticate()
        defer {
            sftp.disconnect()
        }
        
        // Get just the filename from the path
        let filename = filePath.components(separatedBy: "/").last ?? "output"
        // Create torrent in the system's temporary directory
        let outputFile = "/tmp/\(filename).torrent"
        let escapedOutputFile = outputFile.replacingOccurrences(of: "'", with: "'\\''")
        let escapedPath = filePath.replacingOccurrences(of: "'", with: "'\\''")
        
        // Build tracker arguments
        let trackerArgs = tracker.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "-t '\($0)'" }
            .joined(separator: " ")
        
        // Create torrent using transmission-create
        let createCmd = """
            transmission-create \
            -o '\(escapedOutputFile)' \
            \(trackerArgs) \
            '\(escapedPath)'
            """
        
        //commandOutput += "\nExecuting: \(createCmd)"
        commandOutput += "\nStarting Creation"
        
        let ssh = SSHConnection(host: hostname,
                              port: Int(store.selection!.sftpPort),
                              username: username,
                              password: password)
        try await ssh.connect()
        defer { try? ssh.disconnect() }
        
        let (status, output) = try await ssh.executeCommand(createCmd)
        commandOutput += "\n\(output)"
        
        // If we see "pieces" in the output, consider it successful
        if output.contains("pieces") || output.contains("Piece") {
            commandOutput += "\nTorrent created successfully!"
            isCreated = true
            outputPath = outputFile
            
            // Download the torrent file
            isDownloading = true
#if os(macOS)
            commandOutput += "\nDownloading torrent file to your default download location..."
            #else
            commandOutput += "\nDownloading torrent file to the Throttle Folder on your device..."
            #endif
            
            do {
                let downloadFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let localFileName = "\(filename).torrent"
                
                // Create download stream
                let fileManager = FileManager.default
                let outputURL: URL
                                #if os(macOS)
                                outputURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!.appendingPathComponent(localFileName)
                                #else
                                outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(localFileName)
                                #endif
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
                
                if let outputStream = OutputStream(toFileAtPath: outputURL.path, append: false) {
                    try sftp.contents(atPath: outputFile, toStream: outputStream, fromPosition: 0) { current, total in
                        commandOutput += "\nDownloaded: \(current)/\(total) bytes"
                        return true // Continue downloading
                    }
                    localPath = outputURL.path
                    commandOutput += "\nDownloaded to: \(localPath)"
                } else {
                    isError = true
                    throw NSError(domain: "mft", code: MFTErrorCode.local_open_error_for_writing.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "Could not create output file"])
                }
                
                // Clean up temp file
                let (_, _) = try await ssh.executeCommand("rm '\(escapedOutputFile)'")
                commandOutput += "\nCleaned up temporary file"
            } catch {
                isError = true
                commandOutput += "\nError downloading torrent: \(error.localizedDescription)"
            }
            
            isDownloading = false
        } else {
            isError = true
            commandOutput += "\nError: Failed to create torrent file"
            isCreated = false
        }
    }
}

//#endif
