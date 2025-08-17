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
    @State private var currentTask: Task<Void, Never>?
    
    // Remove persistent SSH connection - use create-and-destroy pattern instead
    // @State private var sshConnection: SSHConnection?
    
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
                        if isProcessing {
                            Button("Cancel") {
                                currentTask?.cancel()
                                isProcessing = false
                                progressPercentage = 0
                                commandOutput += "\nOperation cancelled by user"
                            }
                            .foregroundColor(.red)
                        } else {
                            Button {
                                currentTask = Task {
                                    do {
                                        try await createTorrent()
                                    } catch {
                                        await MainActor.run {
                                            errorMessage = "Task cancelled or failed: \(error.localizedDescription)"
                                            showError = true
                                            isProcessing = false
                                        }
                                    }
                                }
                            } label: {
                                Text("Build Torrent")
                            }
                            .disabled(filePath.isEmpty || tracker.isEmpty)
                        }
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
            // Cancel any running task when view disappears
            currentTask?.cancel()
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
    
    private func getTorrentCreateCommand(sourceDirectory: String, sourceName: String, torrentPath: String, tracker: String, serverEntity: ServerEntity) async -> String {
        // Use imdl to create the torrent
        do {
            let (exitCode, output) = try await SSHConnection.executeCommand(on: serverEntity, command: "which imdl || echo '/tmp/imdl-install/imdl'")
            if exitCode == 0 || output.contains("/tmp/imdl-install/imdl") {
                let imdlPath = output.contains("/tmp/imdl-install/imdl") ? "/tmp/imdl-install/imdl" : "imdl"
                
                // Build the command - change to source directory but output torrent to temp location
                let command = "cd '\(sourceDirectory)' && '\(imdlPath)' torrent create --announce '\(tracker)' --output '\(torrentPath)' '\(sourceName)'"
                
                // Log the command for debugging
//                await MainActor.run {
//                    commandOutput += "\nPrepared command: \(command)"
//                }
                
                return command
            }
        } catch {
//            await MainActor.run {
//                commandOutput += "\nError checking imdl: \(error.localizedDescription)"
//            }
        }
        
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
            commandOutput += "\nChecking server tools..."
        }
        
        // Check if imdl is available in PATH
        do {
            let (exitCode, output) = try await connection.executeCommand("which imdl")
            if exitCode == 0 {
                await MainActor.run {
                    commandOutput += "\nimdl found"
                }
                return // imdl is available in PATH
            } else {
                await MainActor.run {
                    commandOutput += "\nchecking imdl install location..."
                }
            }
        } catch {
//            await MainActor.run {
//                commandOutput += "\nError checking PATH: \(error.localizedDescription)"
//            }
        }
        
        // Check if imdl is available in our install location
        do {
            let (exitCode, output) = try await connection.executeCommand("test -f /tmp/imdl-install/imdl && /tmp/imdl-install/imdl --version")
            if exitCode == 0 {
                await MainActor.run {
                    commandOutput += "\nimdl found in install location"
                }
                return // imdl is available in install location
            } else {
//                await MainActor.run {
//                    commandOutput += "\nimdl not found in install location"
//                }
            }
        } catch {
//            await MainActor.run {
//                commandOutput += "\nError checking install location: \(error.localizedDescription)"
//            }
        }
        
        await MainActor.run {
            commandOutput += "\nInitialising imdl..."
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
//            await MainActor.run {
//                commandOutput += "\nRunning installation command..."
//            }
            
            let (installExitCode, output) = try await connection.executeCommand(installCommand)
            
            await MainActor.run {
               // commandOutput += "\nInstallation result (exit code \(installExitCode)): \(output)"
                
                if installExitCode == 0 || output.contains("imdl") {
                    commandOutput += "\nimdl installation completed"
                    progressPercentage = 0.05
                } else {
                    commandOutput += "\nInstallation may have failed"
                }
            }
            
            // Verify installation worked
            let (verifyExitCode, verifyOutput) = try await connection.executeCommand("test -f /tmp/imdl-install/imdl && echo 'imdl available' || echo 'imdl not found'")
            
            await MainActor.run {
                commandOutput += "\nPost-install verification: \(verifyOutput)"
            }
            
            if verifyExitCode != 0 || !verifyOutput.contains("available") {
                throw NSError(domain: "TorrentCreation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to install or verify imdl installation. Server output: \(output)"
                ])
            }
            
        } catch {
            throw NSError(domain: "TorrentCreation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to install imdl. Error: \(error.localizedDescription). Please check network connection and server permissions."
            ])
        }
    }
    
    func createTorrent() async throws {
        // Check if task was cancelled before starting
        try Task.checkCancellation()
        
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
            commandOutput += "\nServer: \(serverEntity.name ?? "Unknown")"
            //commandOutput += "\nHost: \(serverEntity.ip ?? "Unknown")"
        }
        
        // Use the safe connection pattern - create connection for this operation
        try await SSHConnection.withConnection(server: serverEntity) { connection in
            // Check for cancellation before each major step
            try Task.checkCancellation()
            
//            await MainActor.run {
//                commandOutput += "\nEstablishing SSH connection..."
//            }
            
            try await connection.connect()
            
            await MainActor.run {
                progressPercentage = 0.1
                commandOutput += "\nSSH connection established successfully"
            }
            
            try Task.checkCancellation()
            
            // Ensure torrent creation tools are installed
            try await ensureTorrentCreatorInstalled(connection: connection)
            
            await MainActor.run {
                progressPercentage = 0.15
                commandOutput += "\nVerifying source..."
            }
            
            try Task.checkCancellation()
            
            // Verify the source file/directory exists
            let (verifyExitCode, verifyOutput) = try await connection.executeCommand("ls -la '\(filePath)'")
            if verifyExitCode != 0 {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = "Source file/directory not found: \(filePath)\nOutput: \(verifyOutput)"
                    showError = true
                    isError = true
                }
                return
            }
            
            await MainActor.run {
                commandOutput += "\nSource verified: \(verifyOutput.components(separatedBy: .newlines).first ?? "")"
                progressPercentage = 0.18
                commandOutput += "\nPreparing torrent creation..."
            }
            
            // Create torrent in a temp location to avoid permission issues
            let parentDirectory = (filePath as NSString).deletingLastPathComponent
            let fileName = (filePath as NSString).lastPathComponent
            let torrentFileName = "\(fileName).torrent"
            
            // Use a temp directory for torrent output to avoid permission issues
            let tempTorrentDir = "/tmp/imdl-install"
            let torrentPath = "\(tempTorrentDir)/\(torrentFileName)"
            
//            await MainActor.run {
//                commandOutput += "\nEnsuring temp directory exists..."
//            }
            
            // Ensure the temp directory exists and is writable
            let (mkdirExitCode, mkdirOutput) = try await connection.executeCommand("mkdir -p '\(tempTorrentDir)' && echo 'temp_dir_ok' || echo 'temp_dir_failed'")
            
            if !mkdirOutput.contains("temp_dir_ok") {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = "Cannot create temp directory '\(tempTorrentDir)'. Output: \(mkdirOutput)"
                    showError = true
                    isError = true
                }
                return
            }
            
            await MainActor.run {
               // commandOutput += "\nTemp directory ready: \(tempTorrentDir)"
                progressPercentage = 0.19
                //commandOutput += "\nPreparing torrent creation..."
            }
        
        // Check file size for progress estimation
        let fileSize = await monitorFileSize(connection: connection, filePath: filePath)
        let isLargeFile = (fileSize ?? 0) > 100_000_000 // 100MB threshold
        
        // Calculate timeout based on file size (minimum 60 seconds, up to 30 minutes for very large files)
        let timeoutSeconds = min(1800, max(60, Int((fileSize ?? 0) / 1_000_000))) // 1 second per MB
        
        await MainActor.run {
            progressPercentage = 0.2
            //commandOutput += "\nCreating torrent: \(torrentFileName)"
            //commandOutput += "\nSource: \(fileName)"
            //commandOutput += "\nSource location: \(parentDirectory)"
            //commandOutput += "\nTorrent output: \(torrentPath)"
            if let size = fileSize {
                let sizeString = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                commandOutput += "\nFile size: \(sizeString)"
                commandOutput += "\nEstimated timeout: \(timeoutSeconds) seconds"
                if isLargeFile {
                    commandOutput += "\nLarge file detected - creation may take time"
                }
            }
        }
        
        // Get the appropriate torrent creation command
        let createCommand = await getTorrentCreateCommand(
            sourceDirectory: parentDirectory,
            sourceName: fileName,
            torrentPath: torrentPath,
            tracker: tracker,
            serverEntity: serverEntity
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
        
        // Test imdl before proceeding
        await MainActor.run {
            progressPercentage = 0.25
            commandOutput += "\nTesting imdl installation..."
        }
        
        do {
            let imdlPath = createCommand.contains("/tmp/imdl-install/imdl") ? "/tmp/imdl-install/imdl" : "imdl"
            let (testExitCode, testOutput) = try await connection.executeCommand("\(imdlPath) --version")
            
            await MainActor.run {
                if testExitCode == 0 {
                    commandOutput += "\nimdl version: \(testOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
                } else {
                    commandOutput += "\nWarning: imdl test failed (exit code \(testExitCode)): \(testOutput)"
                }
            }
        } catch {
            await MainActor.run {
                commandOutput += "\nWarning: Could not test imdl: \(error.localizedDescription)"
            }
        }
        
        do {
            try Task.checkCancellation()
            
            await MainActor.run {
                progressPercentage = 0.3
                commandOutput += "\nExecuting imdl torrent creator..."
                commandOutput += "\nCommand: \(createCommand)"
                commandOutput += "\nTimeout set to: \(timeoutSeconds) seconds"
                if isLargeFile {
                    commandOutput += "\nLarge file detected - creation may take time"
                }
            }
            
            // Execute the command with real-time output monitoring
            var lastOutput = ""
            var progressTimer = 0.3
            let commandStartTime = Date()
            
            // Start the command asynchronously
            let commandTask = Task {
                return try await connection.executeCommand(createCommand)
            }
            
            // Monitor the command execution with periodic updates
            while !commandTask.isCancelled {
                do {
                    // Try to get the result with a short timeout
                    let result = try await withTimeout(seconds: 5) {
                        try await commandTask.value
                    }
                    
                    // Command completed successfully
                    let (exitCode, output) = result
                    
                    await MainActor.run {
                        progressPercentage = 0.7
                        commandOutput += "\nCommand completed with exit code: \(exitCode)"
                        commandOutput += "\nimdl output: \(output)"
                        
                        let duration = Date().timeIntervalSince(commandStartTime)
                        commandOutput += "\nExecution time: \(String(format: "%.1f", duration)) seconds"
                    }
                    
                    // Check for success/failure
                    if exitCode != 0 {
                        await MainActor.run {
                            isProcessing = false
                            errorMessage = "imdl failed with exit code \(exitCode).\n\nOutput: \(output)\n\nThis usually means:\n- File permissions issue\n- Invalid tracker URL\n- Disk space problem\n- Network connectivity issue"
                            showError = true
                            isError = true
                        }
                        return
                    }
                    
                    // Check for error indicators in output
                    let outputLower = output.lowercased()
                    if outputLower.contains("error") || outputLower.contains("failed") || outputLower.contains("invalid") {
                        await MainActor.run {
                            isProcessing = false
                            errorMessage = "imdl validation error: \(output)"
                            showError = true
                            isError = true
                        }
                        return
                    }
                    
                    // Success - break out of monitoring loop
                    await MainActor.run {
                        commandOutput += "\nimdl torrent creation succeeded!"
                    }
                    break
                    
                } catch {
                    // Command still running, update progress and continue monitoring
                    try Task.checkCancellation() // Check if we were cancelled
                    
                    progressTimer = min(0.65, progressTimer + 0.02)
                    let elapsed = Date().timeIntervalSince(commandStartTime)
                    
                    await MainActor.run {
                        progressPercentage = progressTimer
                        commandOutput += "\nStill processing... (\(String(format: "%.0f", elapsed))s elapsed)"
                    }
                    
                    // If we've been running too long, give a timeout error
                    if elapsed > TimeInterval(timeoutSeconds) {
                        commandTask.cancel()
                        await MainActor.run {
                            isProcessing = false
                            errorMessage = "Operation timed out after \(timeoutSeconds) seconds. The file may be too large or there may be a network issue."
                            showError = true
                            isError = true
                        }
                        return
                    }
                    
                    // Wait a bit before checking again
                    try await Task.sleep(for: .seconds(3))
                }
            }
            
            // Verify the torrent file was created
            await MainActor.run {
                progressPercentage = 0.75
                commandOutput += "\nVerifying torrent file creation..."
            }
            
            let (checkExitCode, fileCheck) = try await connection.executeCommand("ls -la '\(torrentPath)'")
            
            await MainActor.run {
                commandOutput += "\nFile check output: \(fileCheck)"
            }
            
            if checkExitCode != 0 || fileCheck.contains("No such file") || fileCheck.contains("cannot access") {
                await MainActor.run {
                    isProcessing = false
                    progressPercentage = 0
                    errorMessage = "Torrent file was not created at '\(torrentPath)'. Check output: \(fileCheck)"
                    showError = true
                    isError = true
                }
                return
            }
            
            await MainActor.run {
                progressPercentage = 0.8
                commandOutput += "\nTorrent file verified successfully"
                commandOutput += "\nReading torrent file and adding to daemon..."
            }
            
            // Read the torrent file content from the remote server
            let torrentData = try await connection.downloadFileToMemory(remotePath: torrentPath)
            let base64Torrent = torrentData.base64EncodedString()
            
            await MainActor.run {
                progressPercentage = 0.9
                commandOutput += "\nTorrent file downloaded, adding to transmission daemon..."
            }
            
            // Add the torrent to transmission daemon using the metainfo (base64 encoded content)
            let response = try await manager.addTorrent(
                metainfo: base64Torrent,
                downloadDir: parentDirectory
            )
            
            await MainActor.run {
                commandOutput += "\nAdd torrent response: \(String(describing: response))"
            }
            
            if response.result == "success" {
                await MainActor.run {
                    progressPercentage = 1.0
                    commandOutput += "\nTorrent added to daemon successfully!"
                    commandOutput += "\nTorrent ID: \(response.id ?? -1)"
                    commandOutput += "\nTorrent should start seeding immediately since files are already present."
                    isProcessing = false
                    isCreated = true
                    successMessage = "Torrent created and seeding!"
                    showSuccess = true
                }
                
                // Clean up the temporary torrent file
                let (rmExitCode, rmOutput) = try await connection.executeCommand("rm -f '\(torrentPath)'")
                await MainActor.run {
                    if rmExitCode == 0 {
                        commandOutput += "\nTorrent file cleaned up from temp location"
                    } else {
                        commandOutput += "\nWarning: Could not clean up temp torrent file: \(rmOutput)"
                    }
                }
                
                // Optional: Monitor the torrent status briefly
                if let torrentId = response.id {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await checkTorrentStatus(torrentId: torrentId, serverEntity: serverEntity)
                    }
                }
            } else {
                await MainActor.run {
                    isProcessing = false
                    progressPercentage = 0
                    errorMessage = "Failed to add torrent to daemon. Response: \(String(describing: response))"
                    showError = true
                    isError = true
                }
            }
            
        } catch {
            await MainActor.run {
                isProcessing = false
                progressPercentage = 0
                let errorDescription = error.localizedDescription
                commandOutput += "\nERROR: \(errorDescription)"
                
                // Get more detailed error information
                var detailedError = "Error creating torrent: \(errorDescription)"
                
                // Check for specific SSH/Citadel errors
                if let sshError = error as? NSError {
                    commandOutput += "\nError domain: \(sshError.domain)"
                    commandOutput += "\nError code: \(sshError.code)"
                    commandOutput += "\nError userInfo: \(sshError.userInfo)"
                    
                    if sshError.domain.contains("Citadel") {
                        if sshError.code == 1 {
                            detailedError = """
                            SSH Command Failed (Citadel.SSHClient.CommandFailed error 1)
                            
                            This usually means:
                            • The imdl command failed to execute properly
                            • Permission denied accessing files or directories
                            • The imdl binary is not found or not executable
                            • Network connectivity issues during torrent creation
                            • Disk space insufficient on the server
                            
                            Check the SSH connection and try again.
                            If the problem persists, verify:
                            1. File permissions on the source file/directory
                            2. Available disk space on the server
                            3. Network connectivity to tracker URLs
                            """
                        } else {
                            detailedError = "SSH connection error (code \(sshError.code)): \(errorDescription)"
                        }
                    }
                }
                
                // Provide more specific error messages based on content
                if errorDescription.contains("timeout") || errorDescription.contains("Timeout") {
                    detailedError = "Operation timed out. The torrent creation is taking longer than expected. This can happen with very large files or slow connections."
                } else if errorDescription.contains("connection") || errorDescription.contains("Connection") {
                    detailedError = "Connection error: \(errorDescription)\n\nPlease check your SSH connection and try again."
                } else if errorDescription.contains("permission") || errorDescription.contains("Permission") {
                    detailedError = "Permission error: \(errorDescription)\n\nPlease check file permissions and SSH access."
                } else if errorDescription.contains("cancelled") || errorDescription.contains("Cancelled") {
                    detailedError = "Operation was cancelled by user."
                }
                
                errorMessage = detailedError
                showError = true
                isError = true
            }
        }
        } // End of withConnection block
    }
    
    func checkTorrentStatus(torrentId: Int, serverEntity: ServerEntity? = nil) async {
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
                    Swift.print("  - Note: Detailed SSH debugging not available in this context")
                    
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

