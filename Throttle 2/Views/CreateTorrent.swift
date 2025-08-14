import SwiftUI
import KeychainAccess
import CoreData
import Citadel
import NIOCore

struct CreateTorrent: View {
    @ObservedObject var store: Store
    @ObservedObject var presenting: Presenting
    @StateObject var manager: TorrentManager
    @Environment(\.managedObjectContext) var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)],
        animation: .default)
    var servers: FetchedResults<ServerEntity>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    // State variables
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
    @State private var isPrivate = false
    @State private var comment = ""
    @State var progressPercentage: Double = 0.0
    @State private var showSuccess = false
    @State private var showError = false
    @State private var successMessage = ""
    @State private var errorMessage = ""
    
    // Using @State for the connection property since we're in a struct
    @State private var sshConnection: SSHConnection?
    
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
                        
                        Toggle("Private Torrent", isOn: $isPrivate)
                        
                        TextField("Comment (optional)", text: $comment)
                            .textFieldStyle(.automatic)
                        Text("Utilises Intermodal https://imdl.io").font(.caption)
                    }
                }
                
                if isProcessing {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(commandOutput)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if isProcessing && !isCreated && !isError {
                                Spacer().frame(height: 10)
                                
                                // Linear progress view
                                ProgressView(value: progressPercentage)
                                    .progressViewStyle(LinearProgressViewStyle())
                                    .frame(height: 8)
                            }
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
                        .disabled(filePath.isEmpty || isProcessing || tracker.isEmpty)
                    } else {
                        Button {
                            // Seeding starts automatically, but this button can open the torrent client
                            store.addPath = (filePath as NSString).deletingLastPathComponent
                            openFile(path: localPath)
                            
                        } label: {
                            Text("Open in Client")
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
        .onDisappear {
            // Clean up connection if view disappears
            Task {
                if let conn = sshConnection {
                    await conn.disconnect()
                    sshConnection = nil
                }
            }
        }
        .alert("Success", isPresented: $showSuccess) {
            Button("OK") {
                showSuccess = false
                // Optionally dismiss the view after success
                dismiss()
            }
        } message: {
            Text(successMessage)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {
                showError = false
            }
        } message: {
            Text(errorMessage)
        }
    }
    
    func openFile(path: String) {
        let sourceDirectory = (filePath as NSString).deletingLastPathComponent
        store.addPath = sourceDirectory
        
        // Use the full path directly since localPath contains the complete file path
        let fileURL = URL(fileURLWithPath: path)
        
        // Verify the file exists before proceeding
        guard FileManager.default.fileExists(atPath: path) else {
            Swift.print("Error: Torrent file not found at path: \(path)")
            return
        }
        
        // Debug output
        Swift.print("Debug - CreateTorrent openFile:")
        Swift.print("  - Local torrent file path: \(path)")
        Swift.print("  - Original source filePath: \(filePath)")
        Swift.print("  - Setting store.addPath to: \(sourceDirectory)")
        Swift.print("  - File exists: \(FileManager.default.fileExists(atPath: path))")
        
        // First dismiss this view
        dismiss()
        
        // Then trigger the URL handling after a short delay
        Task {
            try await Task.sleep(for: .milliseconds(500))
            store.selectedFile = fileURL
            presenting.activeSheet = "adding"
        }
    }
    
    private func validateTrackerURLs(_ trackers: String) -> (isValid: Bool, errorMessage: String?) {
        let trackerList = trackers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        for tracker in trackerList {
            // Check if URL has valid scheme
            guard let url = URL(string: tracker) else {
                return (false, "Invalid URL format: \(tracker)")
            }
            
            // Check for valid tracker schemes
            let validSchemes = ["http", "https", "udp"]
            guard let scheme = url.scheme?.lowercased(), validSchemes.contains(scheme) else {
                return (false, "Invalid tracker scheme in: \(tracker)\nSupported schemes: http, https, udp")
            }
            
            // Check if host exists
            guard url.host != nil else {
                return (false, "Missing host in tracker URL: \(tracker)")
            }
        }
        
        return (true, nil)
    }
    
    private func getTorrentCreateCommand(parentDirectory: String, torrentFileName: String, fileName: String, tracker: String) async -> String {
        // Use imdl to create the torrent
        do {
            guard let connection = sshConnection else { return "" }
            let (exitCode, output) = try await connection.executeCommand("which imdl || echo '/tmp/imdl-install/imdl'")
            if exitCode == 0 || output.contains("/tmp/imdl-install/imdl") {
                let imdlPath = output.contains("/tmp/imdl-install/imdl") ? "/tmp/imdl-install/imdl" : "imdl"
                return "cd '\(parentDirectory)' && \(imdlPath) torrent create --announce '\(tracker)' --output '\(torrentFileName)' '\(fileName)'"
            }
        } catch {}
        
        return ""
    }
    
    private func monitorFileSize(connection: SSHConnection, filePath: String) async -> Int64? {
        do {
            let (_, output) = try await connection.executeCommand("du -sb '\(filePath)' | cut -f1")
            return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw NSError(domain: "Timeout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out"])
            }
            
            guard let result = try await group.next() else {
                throw NSError(domain: "Timeout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Task group failed"])
            }
            
            group.cancelAll()
            return result
        }
    }
    
    private func ensureTorrentCreatorInstalled(connection: SSHConnection) async throws {
        await MainActor.run {
            progressPercentage = 0.02
            commandOutput += "\nChecking for imdl (intermodal)..."
        }
        
        // Check if imdl is available in PATH
        do {
            let (exitCode, _) = try await connection.executeCommand("which imdl")
            if exitCode == 0 {
                await MainActor.run {
                    commandOutput += "\nimdl found in PATH"
                }
                return // imdl is available in PATH
            }
        } catch {
            // Continue checking other locations
        }
        
        // Check if imdl is available in our install location
        do {
            let (exitCode, _) = try await connection.executeCommand("test -f /tmp/imdl-install/imdl && /tmp/imdl-install/imdl --version")
            if exitCode == 0 {
                await MainActor.run {
                    commandOutput += "\nimdl found in /tmp/imdl-install/"
                }
                return // imdl is available in install location
            }
        } catch {
            // Continue to installation
        }
        
        await MainActor.run {
            commandOutput += "\nimdl not found. Installing imdl (intermodal torrent creator)..."
            progressPercentage = 0.03
        }
        
        // Install imdl using the official installer
        let installCommand = """
        cd /tmp && \
        curl --proto '=https' --tlsv1.2 -sSf https://imdl.io/install.sh | bash -s -- --to /tmp/imdl-install && \
        cp /tmp/imdl-install/imdl ~/.local/bin/ 2>/dev/null || cp /tmp/imdl-install/imdl /usr/local/bin/ 2>/dev/null || cp /tmp/imdl-install/imdl ~/bin/ 2>/dev/null || echo "imdl downloaded to /tmp/imdl-install/imdl" && \
        which imdl || echo "imdl installed to /tmp/imdl-install/imdl"
        """
        
        do {
            let (_, output) = try await connection.executeCommand(installCommand)
            await MainActor.run {
                commandOutput += "\nInstallation completed"
                commandOutput += "\nimdl ready for use"
                progressPercentage = 0.05
            }
        } catch {
            throw NSError(domain: "TorrentCreation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to install imdl. Please check network connection and try again."
            ])
        }
    }
    
    func createTorrent() async throws {
        await MainActor.run {
            isProcessing = true
            progressPercentage = 0.01
            commandOutput = "Starting torrent creation..."
            isError = false
            isCreated = false
        }
        
        // Validate tracker URLs first
        let validationResult = validateTrackerURLs(tracker)
        if !validationResult.isValid {
            await MainActor.run {
                isProcessing = false
                errorMessage = validationResult.errorMessage ?? "Invalid tracker URL"
                showError = true
                isError = true
            }
            return
        }
        
        await MainActor.run {
            commandOutput += "\nTracker URLs validated"
            progressPercentage = 0.05
        }
        
        // Ensure we have a server selected
        guard let serverEntity = store.selection else {
            await MainActor.run {
                isProcessing = false
                errorMessage = "No server selected"
                showError = true
                isError = true
            }
            return
        }
        
        await MainActor.run {
            commandOutput += "\nConnecting to server..."
        }
        
        // Create and connect SSH connection if needed
        if sshConnection == nil {
            sshConnection = SSHConnection(server: serverEntity)
        }
        
        guard let connection = sshConnection else {
            await MainActor.run {
                isProcessing = false
                errorMessage = "Failed to create SSH connection"
                showError = true
                isError = true
            }
            return
        }
        
        // Connect to the server
        try await connection.connect()
        
        await MainActor.run {
            progressPercentage = 0.1
            commandOutput += "\nConnected to server"
        }
        
        // Ensure torrent creation tools are installed
        try await ensureTorrentCreatorInstalled(connection: connection)
        
        await MainActor.run {
            progressPercentage = 0.15
            commandOutput += "\nPreparing torrent creation..."
        }
        
        // Simple approach: Create torrent in the parent directory of the files
        let parentDirectory = (filePath as NSString).deletingLastPathComponent
        let fileName = (filePath as NSString).lastPathComponent
        let torrentFileName = "\(fileName).torrent"
        let torrentPath = "\(parentDirectory)/\(torrentFileName)"
        
        // Check file size for progress estimation
        let fileSize = await monitorFileSize(connection: connection, filePath: filePath)
        let isLargeFile = (fileSize ?? 0) > 100_000_000 // 100MB threshold
        
        await MainActor.run {
            progressPercentage = 0.2
            commandOutput += "\nCreating torrent: \(torrentFileName)"
            commandOutput += "\nSource: \(fileName)"
            commandOutput += "\nLocation: \(parentDirectory)"
            if let size = fileSize {
                let sizeString = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                commandOutput += "\nFile size: \(sizeString)"
                if isLargeFile {
                    commandOutput += "\nLarge file detected - creation may take time"
                }
            }
        }
        
        // Get the appropriate torrent creation command
        let createCommand = await getTorrentCreateCommand(
            parentDirectory: parentDirectory,
            torrentFileName: torrentFileName,
            fileName: fileName,
            tracker: tracker
        )
        
        guard !createCommand.isEmpty else {
            await MainActor.run {
                isProcessing = false
                errorMessage = "No torrent creation tool available"
                showError = true
                isError = true
            }
            return
        }
        
        do {
            await MainActor.run {
                progressPercentage = 0.3
                commandOutput += "\nExecuting imdl torrent creator..."
                if isLargeFile {
                    commandOutput += "\nPlease wait, processing large file..."
                }
            }
            
            // For large files, monitor progress
            if isLargeFile {
                // Start the command in background and monitor
                let backgroundTask = Task {
                    return try await connection.executeCommand(createCommand)
                }
                
                // Monitor progress for large files
                var progressMonitor = 0.3
                while !backgroundTask.isCancelled {
                    do {
                        let result = try await withTimeout(seconds: 2) {
                            try await backgroundTask.value
                        }
                        // Command completed
                        let (_, output) = result
                        await MainActor.run {
                            progressPercentage = 0.7
                            commandOutput += "\nTorrent creation completed"
                            commandOutput += "\nOutput: \(output)"
                        }
                        break
                    } catch {
                        // Still running, update progress
                        progressMonitor = min(0.65, progressMonitor + 0.05)
                        await MainActor.run {
                            progressPercentage = progressMonitor
                        }
                        try await Task.sleep(for: .seconds(3))
                    }
                }
            } else {
                // Regular execution for smaller files
                let (_, output) = try await connection.executeCommand(createCommand)
                
                await MainActor.run {
                    progressPercentage = 0.7
                    commandOutput += "\nTorrent creation completed"
                    commandOutput += "\nOutput: \(output)"
                }
                
                // Check for imdl validation errors in output
                if output.lowercased().contains("error") || output.lowercased().contains("invalid") {
                    await MainActor.run {
                        isProcessing = false
                        errorMessage = "imdl validation error: \(output)"
                        showError = true
                        isError = true
                    }
                    return
                }
            }
            
            // Verify the torrent file was created
            let (_, fileCheck) = try await connection.executeCommand("ls -la '\(torrentPath)'")
            if fileCheck.contains("No such file") {
                await MainActor.run {
                    isProcessing = false
                    progressPercentage = 0
                    errorMessage = "Torrent file was not created"
                    showError = true
                    isError = true
                }
                return
            }
            
            await MainActor.run {
                progressPercentage = 0.8
                commandOutput += "\nTorrent file created successfully"
                commandOutput += "\nReading torrent file and adding to daemon..."
            }
            
            // Read the torrent file content from the remote server
            let torrentData = try await connection.downloadFileToMemory(remotePath: torrentPath)
            let base64Torrent = torrentData.base64EncodedString()
            
            // Add the torrent to transmission daemon using the metainfo (base64 encoded content)
            let response = try await manager.addTorrent(
                metainfo: base64Torrent,
                downloadDir: parentDirectory
            )
            
            if response.result == "success" {
                await MainActor.run {
                    progressPercentage = 1.0
                    commandOutput += "\nTorrent added to daemon successfully!"
                    commandOutput += "\nTorrent should start seeding immediately since files are already present."
                    isProcessing = false
                    isCreated = true
                    successMessage = "Torrent created and seeding!"
                    showSuccess = true
                }
                
                // Clean up the torrent file
                try? await connection.executeCommand("rm -f '\(torrentPath)'")
                
                // Optional: Monitor the torrent status briefly
                if let torrentId = response.id {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await checkTorrentStatus(torrentId: torrentId)
                    }
                }
            } else {
                await MainActor.run {
                    isProcessing = false
                    progressPercentage = 0
                    errorMessage = "Failed to add torrent to daemon"
                    showError = true
                    isError = true
                }
            }
            
        } catch {
            await MainActor.run {
                isProcessing = false
                progressPercentage = 0
                errorMessage = "Error creating torrent: \(error.localizedDescription)"
                showError = true
                isError = true
            }
        }
    }
    
    func checkTorrentStatus(torrentId: Int) async {
        do {
            if let torrent = try await manager.fetchTorrentDetails(id: torrentId) {
                let statusDescription = getStatusDescription(status: torrent.status ?? 0)
                
                Swift.print("Debug - Torrent Status Check:")
                Swift.print("  - Name: \(torrent.name)")
                Swift.print("  - Status: \(torrent.status) (\(statusDescription))")
                Swift.print("  - Progress: \(String(format: "%.1f", (torrent.percentDone ?? 0.0) * 100))%")
                
                await MainActor.run {
                    if torrent.status == 6 {
                        commandOutput += "\nConfirmed: Torrent is seeding!"
                    } else {
                        commandOutput += "\nStatus: \(statusDescription)"
                        if torrent.status == 2 {
                            commandOutput += " (Transmission is verifying files)"
                        }
                    }
                }
            }
        } catch {
            Swift.print("Error checking torrent status: \(error)")
        }
    }
    
    func getStatusDescription(status: Int) -> String {
        switch status {
        case 0: return "Stopped"
        case 1: return "Check waiting"
        case 2: return "Checking files"
        case 3: return "Download waiting"
        case 4: return "Downloading"
        case 5: return "Seed waiting"
        case 6: return "Seeding"
        default: return "Unknown (\(status))"
        }
    }
    
    // Helper function to format file sizes nicely
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    // Check torrent status after adding to see what transmission is doing
    private func checkTorrentStatus(torrentId: Int, manager: TorrentManager) async {
        do {
            // Wait a moment for transmission to process the torrent
            try await Task.sleep(for: .seconds(2))
            
            Swift.print("Debug - Checking torrent status for ID: \(torrentId)")
            
            // Get detailed torrent info from transmission
            if let torrent = try await manager.fetchTorrentDetails(id: torrentId) {
                Swift.print("Debug - Torrent Status:")
                Swift.print("  - Name: \(torrent.name ?? "Unknown")")
                Swift.print("  - Status: \(torrent.status ?? -1)")
                Swift.print("  - Status Description: \(getStatusDescription(torrent.status ?? -1))")
                Swift.print("  - Progress: \(String(format: "%.1f", (torrent.percentDone ?? 0) * 100))%")
                Swift.print("  - Size: \(torrent.totalSize ?? 0) bytes")
                Swift.print("  - Downloaded: \(torrent.downloadedEver ?? 0) bytes")
                Swift.print("  - Uploaded: \(torrent.uploadedEver ?? 0) bytes")
                Swift.print("  - Download Dir: \(torrent.downloadDir ?? "Unknown")")
                Swift.print("  - Error: \(torrent.errorString ?? "None")")
                Swift.print("  - Wanted files: \(torrent.wanted?.count ?? 0)")
                
                let status = torrent.status ?? -1
                
                // Update UI based on status
                await MainActor.run {
                    commandOutput += "\n\nTorrent Status Check:"
                    commandOutput += "\n- Status: \(getStatusDescription(status))"
                    commandOutput += "\n- Progress: \(String(format: "%.1f", (torrent.percentDone ?? 0) * 100))%"
                    if let error = torrent.errorString, !error.isEmpty {
                        commandOutput += "\n- Error: \(error)"
                    }
                }
                
                // Check if transmission is verifying the files
                if status == 2 { // TR_STATUS_CHECK
                    Swift.print("  - Transmission is currently verifying files...")
                    await MainActor.run {
                        commandOutput += "\n- Transmission is verifying files, please wait..."
                    }
                    
                    // Continue monitoring until verification is complete
                    try await Task.sleep(for: .seconds(5))
                    await checkTorrentStatus(torrentId: torrentId, manager: manager)
                    
                } else if status == 4 { // TR_STATUS_DOWNLOAD
                    Swift.print("  - Transmission thinks this needs to be downloaded (files not found or incomplete)")
                    Swift.print("  - This suggests the daemon cannot locate or verify the existing files")
                    
                    // Check file accessibility from transmission's perspective
                    let fileName = torrent.name ?? "Unknown"
                    let downloadDir = torrent.downloadDir ?? ""
                    let fullPath = "\(downloadDir)/\(fileName)"
                    
                    Swift.print("  - Checking file accessibility for transmission daemon...")
                    
                    // Enhanced debugging - check file permissions and transmission user access
                    if let connection = sshConnection {
                        // Get detailed file information
                        let escapedPath = fullPath.replacingOccurrences(of: "'", with: "'\\''")
                        let (_, lsOutput) = try await connection.executeCommand("ls -la '\(escapedPath)' 2>/dev/null || echo 'FILE_NOT_FOUND'")
                        Swift.print("  - File details: \(lsOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                        
                        // Check what user transmission daemon is running as
                        let (_, transmissionUser) = try await connection.executeCommand("ps aux | grep transmission-daemon | grep -v grep | awk '{print $1}' | head -1")
                        let actualUser = transmissionUser.trimmingCharacters(in: .whitespacesAndNewlines)
                        Swift.print("  - Transmission daemon running as user: \(actualUser)")
                        
                        // Check permissions for the actual transmission daemon user
                        if !actualUser.isEmpty && actualUser != "grep" {
                            let (_, actualUserPermCheck) = try await connection.executeCommand("sudo -u \(actualUser) test -r '\(escapedPath)' 2>/dev/null && echo 'READABLE_BY_\(actualUser.uppercased())' || echo 'NOT_READABLE_BY_\(actualUser.uppercased())'")
                            Swift.print("  - \(actualUser) user access: \(actualUserPermCheck.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                        
                        // Check permissions for transmission user (common users: debian-transmission, transmission)
                        let (_, permCheck1) = try await connection.executeCommand("sudo -u debian-transmission test -r '\(escapedPath)' 2>/dev/null && echo 'READABLE_BY_DEBIAN_TRANSMISSION' || echo 'NOT_READABLE_BY_DEBIAN_TRANSMISSION'")
                        Swift.print("  - Debian-transmission user access: \(permCheck1.trimmingCharacters(in: .whitespacesAndNewlines))")
                        
                        let (_, permCheck2) = try await connection.executeCommand("sudo -u transmission test -r '\(escapedPath)' 2>/dev/null && echo 'READABLE_BY_TRANSMISSION' || echo 'NOT_READABLE_BY_TRANSMISSION'")
                        Swift.print("  - Transmission user access: \(permCheck2.trimmingCharacters(in: .whitespacesAndNewlines))")
                        
                        // Get file hash for verification
                        let (_, hashOutput) = try await connection.executeCommand("sha1sum '\(escapedPath)' 2>/dev/null | cut -d' ' -f1 || echo 'HASH_FAILED'")
                        Swift.print("  - File SHA1: \(hashOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                        
                        // Check directory permissions
                        let parentDir = (downloadDir as NSString).deletingLastPathComponent
                        let (_, dirPermCheck) = try await connection.executeCommand("ls -ld '\(parentDir.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null || echo 'DIR_NOT_FOUND'")
                        Swift.print("  - Parent directory permissions: \(dirPermCheck.trimmingCharacters(in: .whitespacesAndNewlines))")
                        
                        // Try to fix permissions if needed
                        if !actualUser.isEmpty && actualUser != "grep" {
                            let (_, actualUserPermCheck) = try await connection.executeCommand("sudo -u \(actualUser) test -r '\(escapedPath)' 2>/dev/null && echo 'READABLE' || echo 'NOT_READABLE'")
                            if actualUserPermCheck.contains("NOT_READABLE") {
                                Swift.print("  - WARNING: File not readable by transmission daemon user (\(actualUser))!")
                                Swift.print("  - Attempting to fix permissions...")
                                let (_, chmodResult) = try await connection.executeCommand("sudo chmod 644 '\(escapedPath)' && sudo chown \(actualUser):\(actualUser) '\(escapedPath)' 2>/dev/null; echo 'PERMISSION_FIX_ATTEMPTED'")
                                Swift.print("  - Permission fix result: \(chmodResult.trimmingCharacters(in: .whitespacesAndNewlines))")
                            } else {
                                Swift.print("  - File IS readable by transmission daemon user (\(actualUser))")
                                Swift.print("  - This suggests the issue may not be file permissions...")
                            }
                        }
                    }
                    
                    await MainActor.run {
                        showError = true
                        errorMessage = """
                        Torrent is downloading instead of seeding.
                        
                        This means transmission daemon cannot verify the existing files.
                        
                        Common solutions:
                        1. Check file permissions (files need to be readable by transmission user)
                        2. Verify exact file path: \(fullPath)
                        3. Ensure transmission daemon has access to the directory
                        4. Wait for transmission to complete file verification
                        
                        The monitoring will continue checking status automatically.
                        """
                    }
                    
                    // Continue monitoring - transmission might still be verifying
                    Swift.print("  - Continuing to monitor - transmission may still be verifying files...")
                    try await Task.sleep(for: .seconds(10))
                    await checkTorrentStatus(torrentId: torrentId, manager: manager)
                    
                } else if status == 6 { // TR_STATUS_SEED
                    Swift.print("  - Transmission is seeding successfully!")
                    await MainActor.run {
                        showSuccess = true
                        successMessage = "Torrent successfully created and seeding!\n\nName: \(torrent.name ?? "Unknown")\nStatus: Seeding\nSize: \(formatBytes(UInt64(torrent.totalSize ?? 0)))"
                        isCreated = true
                        isProcessing = false
                    }
                    
                } else if status == 0 && !(torrent.errorString?.isEmpty ?? true) {
                    Swift.print("  - Torrent stopped with error: \(torrent.errorString ?? "")")
                    await MainActor.run {
                        showError = true
                        errorMessage = "❌ Torrent creation failed.\n\nError: \(torrent.errorString ?? "Unknown error")"
                    }
                    
                } else if status == 5 { // TR_STATUS_SEED_WAIT
                    Swift.print("  - Torrent is queued for seeding...")
                    await MainActor.run {
                        commandOutput += "\n- Torrent is queued for seeding, waiting..."
                    }
                    
                    // Continue monitoring
                    try await Task.sleep(for: .seconds(3))
                    await checkTorrentStatus(torrentId: torrentId, manager: manager)
                }
                
            }
        } catch {
            Swift.print("Debug - Error checking torrent status: \(error)")
            await MainActor.run {
                showError = true
                errorMessage = "❌ Error checking torrent status: \(error.localizedDescription)"
            }
        }
    }
    
    private func getStatusDescription(_ status: Int) -> String {
        switch status {
        case 0: return "Stopped"
        case 1: return "Check waiting"
        case 2: return "Checking files"
        case 3: return "Download waiting"
        case 4: return "Downloading"
        case 5: return "Seed waiting"
        case 6: return "Seeding"
        default: return "Unknown (\(status))"
        }
    }
}

