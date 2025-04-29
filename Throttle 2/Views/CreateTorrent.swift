import SwiftUI
import KeychainAccess
import CoreData
import Citadel
import NIOCore

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
        .onDisappear {
            // Clean up connection if view disappears
            Task {
                if let conn = sshConnection {
                    await conn.disconnect()
                    sshConnection = nil
                }
            }
        }
    }
    
    func openFile(path: String) {
        store.addPath = (filePath as NSString).deletingLastPathComponent
        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let filename = URL(string: path)?.lastPathComponent {
            let fileURL = documentsURL.appendingPathComponent(filename)
            
            // First dismiss this view
            dismiss()
            
            // Then trigger the URL handling after a short delay
            Task {
                try await Task.sleep(for: .milliseconds(500))
                store.selectedFile = fileURL
                presenting.activeSheet = "adding"
            }
        }
    }
    
    func createTorrent() async throws {
        isProcessing = true
        isError = false
        commandOutput = "Connecting to server..."
        
        // Get script from bundle
        guard let scriptURL = Bundle.main.url(forResource: "torrent_creator", withExtension: "sh"),
              let scriptContent = try? String(contentsOf: scriptURL) else {
            isError = true
            commandOutput += "\nError: Could not load torrent creator script from app bundle"
            return
        }
        
        guard let serverEntity = store.selection else {
            isError = true
            commandOutput += "\nError: No server selected"
            return
        }
        
        // Create a reusable SSH connection
        let connection = SSHConnection(server: serverEntity)
        self.sshConnection = connection
        
        // Connect to the server
        try await connection.connect()
        
        // Set initial progress
        await MainActor.run {
            progressPercentage = 0.05 // Start with a small initial progress
        }
        
        // Get just the filename from the path
        let filename = filePath.components(separatedBy: "/").last ?? "output"
        // Create torrent in the system's temporary directory
        let outputFile = "/tmp/\(filename).torrent"
        let escapedOutputFile = outputFile.replacingOccurrences(of: "'", with: "'\\''")
        let escapedPath = filePath.replacingOccurrences(of: "'", with: "'\\''")
        
        // Upload the shell script to the server
        let scriptPath = "/tmp/torrent_creator.sh"
        
        // Write the script to the server
        commandOutput += "\nPreparing the server..."
        
        await MainActor.run {
            progressPercentage = 0.1 // Script upload starting
        }
        
        // Use cat and shell redirection to create the file
        let createScriptCmd = "cat > '\(scriptPath)' << 'EOFSCRIPT'\n\(scriptContent)\nEOFSCRIPT"
        let (_, _) = try await connection.executeCommand(createScriptCmd)
        
        await MainActor.run {
            progressPercentage = 0.15 // Script uploaded
        }
        
        // Make the script executable
        let (_, _) = try await connection.executeCommand("chmod +x '\(scriptPath)'")
        
        await MainActor.run {
            progressPercentage = 0.2 // Script ready
        }
        
        // Build tracker arguments
        let trackersList = tracker.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        guard let mainTracker = trackersList.first else {
            isError = true
            commandOutput += "\nError: At least one tracker URL is required"
            return
        }
        
        // Build the shell script command
        var shellCmd = [scriptPath]
        
        // Add options
        if isPrivate {
            shellCmd.append("-p")
        }
        
        if !comment.isEmpty {
            shellCmd.append("-c")
            shellCmd.append("'\(comment.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        
        // Add output file
        shellCmd.append("-o")
        shellCmd.append("'\(escapedOutputFile)'")
        
        // Add source path and tracker
        shellCmd.append("'\(escapedPath)'")
        shellCmd.append("'\(mainTracker)'")
        
        // Add additional trackers if any
        for additionalTracker in trackersList.dropFirst() {
            shellCmd.append("-t")
            shellCmd.append("'\(additionalTracker.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        
        // Create a unique ID for this job
        let jobId = UUID().uuidString.prefix(8)
        let logFile = "/tmp/torrent_creation_\(jobId).log"
        
        // Run in background with output redirected to log file
        let backgroundCmd = """
        nohup bash -c "\(shellCmd.joined(separator: " "))" > \(logFile) 2>&1 &
        echo $! > /tmp/torrent_pid_\(jobId)
        """
        
        commandOutput += "\nStarting torrent creation in background..."
        
        await MainActor.run {
            progressPercentage = 0.25 // Starting torrent creation
        }
        
        // Execute the background command - this should return quickly
        let (_, bgOutput) = try await connection.executeCommand(backgroundCmd)
        
        // Start monitoring for the output file
        commandOutput += "\nMonitoring for torrent file creation..."
        
        // Add a status line that we'll update
        commandOutput += "\nProgress: Initializing..."
        
        var fileExists = false
        var attempts = 0
        let maxAttempts = 120 // 10 minutes at 5-second intervals
        var lastLogSize = 0
        var currentProgressLine = "Progress: Initializing..."
        var lastProgressLineIndex = commandOutput.components(separatedBy: "\n").count - 1
        
        // Track pieces progress for the progress bar
        var totalPieces: Int? = nil
        var processedPieces: Int = 0
        
        // Size-based progress tracking
        var totalSize: Int64? = nil
        var pieceSize: Int64? = nil
        var expectedPieces: Int? = nil
        
        while !fileExists && attempts < maxAttempts {
            attempts += 1
            
            // 1. Check the log file for new output
            let (_, logSizeStr) = try await connection.executeCommand("stat -c%s \(logFile) 2>/dev/null || echo '0'")
            let currentLogSize = Int(logSizeStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            
            var updatedProgressLine = false
            
            if currentLogSize > lastLogSize {
                // Get only the new content since last check
                let (_, newContent) = try await connection.executeCommand("tail -c +\(lastLogSize + 1) \(logFile)")
                
                if !newContent.isEmpty {
                    // Look for total size information
                    if totalSize == nil {
                        // Match pattern like "Total size: 21391999 bytes"
                        if let sizeMatch = newContent.range(of: "[Tt]otal size:?\\s*(\\d+)\\s*bytes", options: .regularExpression) {
                            let sizeString = newContent[sizeMatch]
                            if let numberMatch = sizeString.range(of: "\\d+", options: .regularExpression) {
                                totalSize = Int64(newContent[numberMatch])
                            }
                        }
                    }
                    
                    // Look for piece size information
                    if pieceSize == nil {
                        // Match pattern like "Using piece size: 16 KB"
                        if let pieceSizeMatch = newContent.range(of: "[Uu]sing piece size:?\\s*(\\d+)\\s*KB", options: .regularExpression) {
                            let pieceSizeString = newContent[pieceSizeMatch]
                            if let numberMatch = pieceSizeString.range(of: "\\d+", options: .regularExpression) {
                                if let kbSize = Int64(newContent[numberMatch]) {
                                    pieceSize = kbSize * 1024 // Convert KB to bytes
                                    
                                    // Calculate expected pieces
                                    if let totalBytes = totalSize, pieceSize! > 0 {
                                        expectedPieces = Int((totalBytes + pieceSize! - 1) / pieceSize!) // Ceiling division
                                    }
                                }
                            }
                        }
                    }
                    
                    // Extract total pieces information if we don't have it yet
                    if totalPieces == nil && expectedPieces == nil {
                        // Look for patterns like "Total pieces: 123" or similar
                        if let totalMatch = newContent.range(of: "([Tt]otal|[Nn]umber of) pieces:?\\s*(\\d+)", options: .regularExpression) {
                            let totalString = newContent[totalMatch]
                            if let numberMatch = totalString.range(of: "\\d+", options: .regularExpression) {
                                totalPieces = Int(newContent[numberMatch]) ?? 100
                            }
                        }
                    }
                    
                    // Check for piece processing pattern (assuming format like "Processed X pieces")
                    if let piecesMatch = newContent.range(of: "Processed\\s+(\\d+)\\s+pieces", options: .regularExpression) {
                        let piecesInfo = newContent[piecesMatch]
                        currentProgressLine = "Progress: \(piecesInfo)"
                        updatedProgressLine = true
                        
                        // Extract the number of processed pieces for progress bar
                        if let numberMatch = piecesInfo.range(of: "\\d+", options: .regularExpression) {
                            if let pieces = Int(newContent[numberMatch]) {
                                processedPieces = pieces
                                
                                // Update progress percentage
                                if let expected = expectedPieces, expected > 0 {
                                    // Calculate progress but keep it between 25-90%
                                    // We started at 25% and want to leave room for download
                                    let calculatedProgress = Double(processedPieces) / Double(expected)
                                    let adjustedProgress = 0.25 + (calculatedProgress * 0.65)
                                    
                                    await MainActor.run {
                                        progressPercentage = min(0.9, adjustedProgress)
                                    }
                                } else if let total = totalPieces, total > 0 {
                                    // Fall back to total pieces if available
                                    let calculatedProgress = Double(processedPieces) / Double(total)
                                    let adjustedProgress = 0.25 + (calculatedProgress * 0.65)
                                    
                                    await MainActor.run {
                                        progressPercentage = min(0.9, adjustedProgress)
                                    }
                                } else {
                                    // If we don't know total, make progress "bounce"
                                    await MainActor.run {
                                        // Calculate a percentage that oscillates between 30% and 80%
                                        let time = Double(attempts % 10) / 10.0
                                        let oscillating = 0.5 + 0.25 * sin(Double.pi * 2 * time)
                                        progressPercentage = oscillating
                                    }
                                }
                            }
                        }
                    }
                    // Also look for other important messages we want to show (like errors or completion)
                    else if newContent.contains("error") || newContent.contains("Error") ||
                            newContent.contains("complete") || newContent.contains("finished") {
                        // For important messages, add a new line
                        commandOutput += "\n\(newContent)"
                    }
                    else if !updatedProgressLine {
                        // For other log content that's not about piece processing
                        // Check if it contains any other useful progress information
                        let lines = newContent.components(separatedBy: "\n")
                        for line in lines where !line.isEmpty {
                            if line.contains("piece") || line.contains("hash") || line.contains("size") ||
                               line.contains("progress") || line.contains("file") {
                                currentProgressLine = "Progress: \(line)"
                                updatedProgressLine = true
                                break
                            }
                        }
                    }
                }
                
                lastLogSize = currentLogSize
            }
            
            // 2. Check if the output file exists
            let (_, checkOutput) = try await connection.executeCommand("[ -f '\(escapedOutputFile)' ] && echo 'success' || echo 'failed'")
            
            if checkOutput.contains("success") {
                fileExists = true
                commandOutput += "\nTorrent file created successfully!"
                isCreated = true
                outputPath = outputFile
                
                await MainActor.run {
                    progressPercentage = 0.9 // Creation complete, ready to download
                }
                break
            } else {
                // 3. Check if process is still running
                let (_, pidFileExists) = try await connection.executeCommand("[ -f /tmp/torrent_pid_\(jobId) ] && echo 'yes' || echo 'no'")
                
                if pidFileExists.contains("yes") {
                    let (_, pidContent) = try await connection.executeCommand("cat /tmp/torrent_pid_\(jobId)")
                    let pid = pidContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    let (_, processCheck) = try await connection.executeCommand("ps -p \(pid) -o pid= || echo 'NOT_RUNNING'")
                    if processCheck.contains("NOT_RUNNING") {
                        // Process ended but no file found - check log for errors
                        let (_, finalLog) = try await connection.executeCommand("cat \(logFile)")
                        if !finalLog.contains("success") && !finalLog.contains("pieces") {
                            isError = true
                            commandOutput += "\nProcess completed but no torrent file was created."
                            commandOutput += "\nError details from log:\n\(finalLog)"
                            
                            await MainActor.run {
                                progressPercentage = 0 // Error state
                            }
                            return
                        }
                        
                        // Re-check for file one last time
                        let (_, finalCheck) = try await connection.executeCommand("[ -f '\(escapedOutputFile)' ] && echo 'success' || echo 'failed'")
                        if finalCheck.contains("success") {
                            fileExists = true
                            commandOutput += "\nTorrent file created successfully!"
                            isCreated = true
                            outputPath = outputFile
                            
                            await MainActor.run {
                                progressPercentage = 0.9 // Creation complete, ready to download
                            }
                            break
                        } else {
                            isError = true
                            commandOutput += "\nError: Process completed but no torrent file was found"
                            
                            await MainActor.run {
                                progressPercentage = 0 // Error state
                            }
                            return
                        }
                    }
                }
                
                // Only update the progress indication every check
                if !updatedProgressLine {
                    // If no new log content for progress, update with time elapsed
                    currentProgressLine = "Progress: Working... (\(attempts * 5) seconds elapsed)"
                    
                    // If we don't have specific progress info, make the progress bar oscillate
                    if totalPieces == nil && expectedPieces == nil {
                        await MainActor.run {
                            // Calculate a percentage that oscillates between 30% and 80%
                            let time = Double(attempts % 10) / 10.0
                            let oscillating = 0.5 + 0.25 * sin(Double.pi * 2 * time)
                            progressPercentage = oscillating
                        }
                    }
                }
                
                // Update the progress line in-place
                var lines = commandOutput.components(separatedBy: "\n")
                if lastProgressLineIndex < lines.count {
                    lines[lastProgressLineIndex] = currentProgressLine
                    commandOutput = lines.joined(separator: "\n")
                }
                
                // Wait 5 seconds before checking again
                try await Task.sleep(for: .seconds(5))
            }
        }
        
        if !fileExists {
            isError = true
            commandOutput += "\nError: Torrent creation timed out after \(attempts * 5) seconds"
            
            await MainActor.run {
                progressPercentage = 0 // Error state
            }
            return
        }
        
        // Download the torrent file
        isDownloading = true
    #if os(macOS)
        commandOutput += "\nDownloading torrent file to your default download location..."
    #else
        commandOutput += "\nDownloading torrent file to the Throttle Folder on your device..."
    #endif
        
        // Add a download progress line that we'll update
        commandOutput += "\nDownload: Starting..."
        let downloadLineIndex = commandOutput.components(separatedBy: "\n").count - 1
        
        do {
            let fileManager = FileManager.default
            let outputURL: URL
    #if os(macOS)
            outputURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!.appendingPathComponent("\(filename).torrent")
    #else
            outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("\(filename).torrent")
    #endif
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            
            // Download using our single SSH connection
            // Create a modified progress handler that matches the expected signature
            let progressHandler: (Double) -> Void = { progress in
                let current = UInt64(progress * 100000) // Estimate of bytes for progress display
                let total = UInt64(100000)
                let percentage = Int(progress * 100)
                let downloadProgressLine = "Download: \(formatBytes(current))/\(formatBytes(total)) (\(percentage)%)"
                
                // Update progress bar for download (90-100%)
                let adjustedProgress = 0.9 + (progress * 0.1) // 90-100% range
                
                Task { @MainActor in
                    progressPercentage = min(1.0, adjustedProgress)
                }
                
                // Update the download line in-place
                Task { @MainActor in
                    var lines = commandOutput.components(separatedBy: "\n")
                    if downloadLineIndex < lines.count {
                        lines[downloadLineIndex] = downloadProgressLine
                        commandOutput = lines.joined(separator: "\n")
                    }
                }
            }
            
            // Use the same SSH connection for downloading
            try await connection.downloadFile(
                remotePath: outputFile,
                localURL: outputURL,
                progress: progressHandler
            )
            
            localPath = outputURL.path
            commandOutput += "\nDownloaded to: \(localPath)"
            
            await MainActor.run {
                progressPercentage = 1.0 // Complete
            }
            
            // Clean up temp files
            let (_, _) = try await connection.executeCommand("rm -f '\(escapedOutputFile)' '\(scriptPath)' /tmp/torrent_pid_\(jobId) \(logFile)")
            commandOutput += "\nCleaned up temporary files"
        } catch {
            isError = true
            commandOutput += "\nError downloading torrent: \(error.localizedDescription)"
            
            await MainActor.run {
                progressPercentage = 0 // Error state
            }
        }
        
        isDownloading = false
    }
    
    // Helper function to format file sizes nicely
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
