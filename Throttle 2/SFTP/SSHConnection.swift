import Foundation
import Citadel
import NIOCore
import KeychainAccess
import SwiftUI

// Error types for SSH operations
enum SSHTunnelError: Error {
    case missingCredentials
    case connectionFailed(Error)
    case tunnelEstablishmentFailed(Error)
    case portForwardingFailed(Error)
    case localProxyFailed(Error)
    case reconnectFailed(Error)
    case invalidServerConfiguration
    case tunnelAlreadyConnected
    case tunnelNotConnected
}

// Singleton manager to track and reset all connections
class SSHConnectionManager {
    static let shared = SSHConnectionManager()
    
    private var activeConnections: [SSHConnection] = []
    private let connectionLock = NSLock()
    
    private init() {}
    
    func register(connection: SSHConnection) {
        Task {
            await withCheckedContinuation { continuation in
                connectionLock.lock()
                if !activeConnections.contains(where: { $0 === connection }) {
                    activeConnections.append(connection)
                }
                connectionLock.unlock()
                continuation.resume()
            }
        }
    }
    
    func unregister(connection: SSHConnection) {
        Task {
            await withCheckedContinuation { continuation in
                connectionLock.lock()
                activeConnections.removeAll(where: { $0 === connection })
                connectionLock.unlock()
                continuation.resume()
            }
        }
    }
    
    func resetAllConnections() async {
        let connectionsToReset: [SSHConnection] = await withCheckedContinuation { continuation in
            connectionLock.lock()
            let connections = activeConnections
            connectionLock.unlock()
            continuation.resume(returning: connections)
        }
        
        for connection in connectionsToReset {
            await connection.disconnect()
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            await connection.resetState()
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    
    func handleAppBackgrounding() async {
        await resetAllConnections()
    }
    
    func cleanupBeforeTermination() async {
        await resetAllConnections()
    }
}

// Connection class for both SSH commands and SFTP operations
class SSHConnection {
    private var server: ServerEntity
    private var client: SSHClient?
    private var sftpClient: SFTPClient?
    private var isConnecting: Bool = false
    private var connectionLock = NSLock()
    private var lastActiveTime: Date = Date()
    
    // Connection timeout (1 minute of inactivity)
    private let connectionTimeout: TimeInterval = 60
    
    init(server: ServerEntity) {
        self.server = server
        
        // Register with the connection manager
        SSHConnectionManager.shared.register(connection: self)
    }
    
    func connect() async throws {
        // Use async-safe locking to prevent multiple simultaneous connection attempts
        let alreadyConnecting: Bool = await withCheckedContinuation { continuation in
            connectionLock.lock()
            let result = isConnecting
            if !result {
                isConnecting = true
            }
            connectionLock.unlock()
            continuation.resume(returning: result)
        }
        
        // Check if we're already connecting or connected
        if alreadyConnecting {
            // Wait a moment and check again if connection succeeded
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            let hasClient: Bool = await withCheckedContinuation { continuation in
                connectionLock.lock()
                let result = client != nil
                connectionLock.unlock()
                continuation.resume(returning: result)
            }
            
            if hasClient {
                return
            } else {
                // Previous connection attempt might still be in progress
                // Wait a bit longer
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                
                let hasClientAfterWait: Bool = await withCheckedContinuation { continuation in
                    connectionLock.lock()
                    let result = client != nil
                    connectionLock.unlock()
                    continuation.resume(returning: result)
                }
                
                if hasClientAfterWait {
                    return
                }
            }
            
            // If we still don't have a connection after waiting, start over
            await withCheckedContinuation { continuation in
                connectionLock.lock()
                isConnecting = true
                connectionLock.unlock()
                continuation.resume()
            }
        }
        
        do {
            // Get credentials from keychain
            @AppStorage("useCloudKit") var useCloudKit: Bool = true
            let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
            guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
                throw SSHTunnelError.missingCredentials
            }
            
            // Validate server details
            guard let host = server.sftpHost, let username = server.sftpUser else {
                throw SSHTunnelError.missingCredentials
            }
            
            client = try await SSHClient.connect(
                host: host,
                port: Int(server.sftpPort),
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            
            // Update the last active time
            lastActiveTime = Date()
            
            await withCheckedContinuation { continuation in
                connectionLock.lock()
                isConnecting = false
                connectionLock.unlock()
                continuation.resume()
            }
            
            print("SSH connection established to \(host):\(server.sftpPort)")
        } catch let error as SSHTunnelError {
            await withCheckedContinuation { continuation in
                connectionLock.lock()
                isConnecting = false
                connectionLock.unlock()
                continuation.resume()
            }
            print("SSH connection failed: \(error)")
            throw SSHTunnelError.connectionFailed(error)
        } catch let error as ChannelError where error == ChannelError.connectTimeout(.seconds(30)) {
            await withCheckedContinuation { continuation in
                connectionLock.lock()
                isConnecting = false
                connectionLock.unlock()
                continuation.resume()
            }
            print("SSH connection timed out: \(error)")
            throw SSHTunnelError.connectionFailed(error)
        } catch {
            await withCheckedContinuation { continuation in
                connectionLock.lock()
                isConnecting = false
                connectionLock.unlock()
                continuation.resume()
            }
            print("SSH connection failed with unexpected error: \(error)")
            throw SSHTunnelError.connectionFailed(error)
        }
    }
    
    // Check if the connection is stale based on timeout
    private func isConnectionStale() async -> Bool {
        // If no client exists, it's not stale - it's non-existent
        let hasClient: Bool = await withCheckedContinuation { continuation in
            connectionLock.lock()
            let result = client != nil
            connectionLock.unlock()
            continuation.resume(returning: result)
        }
        
        guard hasClient else { return false }
        
        let currentTime = Date()
        let currentLastActiveTime: Date = await withCheckedContinuation { continuation in
            connectionLock.lock()
            let result = lastActiveTime
            connectionLock.unlock()
            continuation.resume(returning: result)
        }
        
        return currentTime.timeIntervalSince(currentLastActiveTime) > connectionTimeout
    }
    
    // Method to verify and refresh connection if needed
    private func ensureValidConnection() async throws {
        // If connection is stale, disconnect and reconnect
        if await isConnectionStale() {
            await disconnect()
            try await connect()
        } else {
            let hasClient: Bool = await withCheckedContinuation { continuation in
                connectionLock.lock()
                let result = client != nil
                connectionLock.unlock()
                continuation.resume(returning: result)
            }
            
            if !hasClient {
                try await connect()
            }
        }
        
        // Update last active time
        await withCheckedContinuation { continuation in
            connectionLock.lock()
            lastActiveTime = Date()
            connectionLock.unlock()
            continuation.resume()
        }
    }
    
    // Simple method to get the client directly if needed
    func getSSHClient() async throws -> SSHClient {
        try await ensureValidConnection()
        
        guard let client = client else {
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
        }
        
        return client
    }
    
    func listDirectory(path: String, showHidden: Bool = false) async throws -> [FileItem] {
        // Escape the path properly for the shell
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        
        // Construct the command using 'find' to get detailed file information
        // Format: type (d for directory, f for file), size, modification time, name
        var command = """
        cd '\(escapedPath)' && find . -maxdepth 1 -mindepth 1
        """
        
        // Add filter for hidden files if needed
        if !showHidden {
            command += " -not -path '*/\\.*'"
        }
        
        // Add formatting parameters - only include what your struct uses
        command += " -printf \"%y\\t%s\\t%TY-%Tm-%Td %TH:%TM:%TS\\t%f\\n\""
        
        // Execute the SSH command
        let (status, output) = try await executeCommand(command)
        
        // Check for command success
        guard status == 0 else {
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to list directory via SSH"]))
        }
        
        // Parse the command output
        var items: [FileItem] = []
        let lines = output.split(separator: "\n")
        
        for line in lines {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count >= 4 {
                let typeChar = String(parts[0])
                let size = Int(parts[1]) ?? 0
                let dateString = String(parts[2])
                var name = String(parts[3])
                
                // Convert the relative path to absolute
                if name.hasPrefix("./") {
                    name = String(name.dropFirst(2))
                }
                
                let isDirectory = typeChar == "d"
                let fullPath = path + (path.hasSuffix("/") ? "" : "/") + name
                
                // Create a URL from the path
                let url = URL(string: "file://" + fullPath) ?? URL(fileURLWithPath: fullPath)
                
                // Create a date formatter to parse the date
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let date = dateFormatter.date(from: dateString) ?? Date()
                
                // Create the FileItem object using the correct initializer parameters
                let item = FileItem(
                    name: name,
                    url: url,
                    isDirectory: isDirectory,
                    size: size,
                    modificationDate: date
                )
                
                items.append(item)
            }
        }
        
        return items
    }
    
    func executeCommand(_ command: String, maxResponseSize: Int? = nil, mergeStreams: Bool = true) async throws -> (status: Int32, output: String) {
        try await ensureValidConnection()
        
        guard let client = client else {
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
        }
        
        // Update last active time
        lastActiveTime = Date()
        
        // For multi-line commands, always merge streams by default
        let buffer: ByteBuffer
        if let maxSize = maxResponseSize {
            buffer = try await client.executeCommand(command, maxResponseSize: maxSize, mergeStreams: mergeStreams)
        } else {
            // Use a default max response size that's reasonably large (10MB)
            buffer = try await client.executeCommand(command, maxResponseSize: 1024 * 1024 * 10, mergeStreams: mergeStreams)
        }
        
        let output = String(buffer: buffer)
        
        // We don't have access to the exit status with the current API, so we return a default success status
        // In a real implementation, we might want to check for error messages in the output
        return (0, output)
    }
    
    // Helper method for multi-line commands specifically
    func executeMultiLineCommand(_ commands: [String], maxResponseSize: Int? = nil) async throws -> (status: Int32, output: String) {
        // Join commands with proper line endings and execute with merged streams
        let combinedCommand = commands.joined(separator: "\n")
        return try await executeCommand(combinedCommand, maxResponseSize: maxResponseSize, mergeStreams: true)
    }
    
    func executeCommandWithStreams(_ command: String) async throws -> ExecCommandStream {
        try await ensureValidConnection()
        
        guard let client = client else {
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
        }
        
        // Update last active time
        lastActiveTime = Date()
        
        return try await client.executeCommandPair(command)
    }
    
    // Execute interactive shell commands - useful for multi-line commands that need
    // more context or state between lines
    func executeInteractiveCommand(_ command: String) async throws -> ExecCommandStream {
        try await ensureValidConnection()
        
        guard let client = client else {
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
        }
        
        // Update last active time
        lastActiveTime = Date()
        
        // For interactive commands, we use executeCommandPair which gives us
        // direct access to stdin/stdout streams
        return try await client.executeCommandPair(command)
    }
    
    // MARK: - SFTP Operations
    
    /// Open an SFTP session with the server
    func connectSFTP() async throws -> SFTPClient {
        // Make multiple attempts to connect
        let maxAttempts = 3
        var lastError: Error? = nil
        
        for attempt in 1...maxAttempts {
            do {
                try await ensureValidConnection()
                
                guard let client = client else {
                    throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
                }
                
                // Update last active time
                lastActiveTime = Date()
                
                // If we already have an SFTP client, try to use it but verify it's still active
                if let sftp = sftpClient, sftp.isActive {
                    // Verify the SFTP connection is still valid with a simple operation
                    do {
                        _ = try await sftp.listDirectory(atPath: ".")
                        return sftp
                    } catch {
                        // SFTP connection is no longer valid, create a new one
                        print("Existing SFTP connection is invalid, creating new one. Error: \(error)")
                        sftpClient = nil
                    }
                }
                
                // Create a new SFTP client
                let sftp = try await client.openSFTP()
                sftpClient = sftp
                return sftp
            } catch {
                lastError = error
                print("SFTP connection attempt \(attempt) failed: \(error)")
                
                // Completely disconnect and reconnect the base SSH connection
                await disconnect()
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds delay
                
                // Only try to reconnect if we have more attempts left
                if attempt < maxAttempts {
                    try? await connect()
                }
            }
        }
        
        // If we've reached here, all attempts failed
        throw SSHTunnelError.connectionFailed(lastError ?? NSError(domain: "SSHConnection", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to connect to SFTP server after multiple attempts"]))
    }
    
    /// List files in the specified directory path
    func listDirectory(path: String) async throws -> [SFTPPathComponent] {
        let sftp = try await connectSFTP()
        let contents = try await sftp.listDirectory(atPath: path)
        
        // Extract the components from the returned directory listings
        let components = contents.flatMap { $0.components }
        return components
    }
    
    /// Download a file from the remote server using dd if available, falling back to SFTP
    func downloadFile(remotePath: String, localURL: URL, progress: @escaping (Double) -> Void = { _ in }) async throws {
        print("Starting download for \(remotePath)")
        
        // Make sure the directory exists before attempting any download
        let directory = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Create empty file to ensure it exists and is writable
        if !FileManager.default.fileExists(atPath: localURL.path) {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
        }
        
        // First check if dd is available on the remote server
        do {
            let (status, output) = try await executeCommand("which dd")
            print("dd check: status=\(status), output=\(output)")
            
            if status == 0 && !output.isEmpty {
                print("dd is available, trying to use it for download")
                do {
                    try await downloadUsingDD(remotePath: remotePath, localURL: localURL, progress: progress)
                    print("dd download successful for \(remotePath)")
                    return
                } catch {
                    print("dd download failed with error: \(error.localizedDescription), falling back to SFTP")
                }
            } else {
                print("dd not available or check command returned empty result, status: \(status)")
            }
        } catch {
            print("Error checking for dd: \(error.localizedDescription)")
        }
        
        // Fall back to SFTP if dd didn't work or isn't available
        print("Using SFTP fallback for \(remotePath)")
        try await downloadUsingSFTP(remotePath: remotePath, localURL: localURL, progress: progress)
    }

    /// Download a file using dd for potentially better performance
    private func downloadUsingDD(remotePath: String, localURL: URL, progress: @escaping (Double) -> Void) async throws {
        print("Starting dd download for \(remotePath)")
        
        // First, get the file size to track progress
        let sizeCmd = "stat -c %s \"\(remotePath)\" 2>/dev/null || stat -f %z \"\(remotePath)\" 2>/dev/null || echo 0"
        let (_, sizeOutput) = try await executeCommand(sizeCmd)
        let sizeStr = sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        print("Size command output: '\(sizeStr)'")
        
        let fileSize = UInt64(sizeStr) ?? 0
        if fileSize == 0 {
            print("Warning: Could not determine file size, progress reporting will be unavailable")
        }
        
        // Set up command to read the file
        let ddCmd = "dd if=\"\(remotePath)\" bs=32768 status=none"
        print("DD command: \(ddCmd)")
        
        // Get a command stream that we can read from
        let commandStream = try await executeCommandWithStreams(ddCmd)
        
        // Open file for writing
        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer {
            try? fileHandle.close()
        }
        
        var bytesTransferred: UInt64 = 0
        
        // Read from the stream and write to file
        for try await chunk in commandStream.stdout {
            if Task.isCancelled {
                throw CancellationError()
            }
            
            if chunk.readableBytes > 0 {
                // Write chunk to local file
                let data = Data(buffer: chunk)
                try fileHandle.write(contentsOf: data)
                
                // Update progress
                bytesTransferred += UInt64(chunk.readableBytes)
                if fileSize > 0 {
                    progress(Double(bytesTransferred) / Double(fileSize))
                }
            }
        }
        
        // Verify the file was transferred successfully
        if bytesTransferred == 0 {
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "No data transferred with dd"]))
        }
        
        print("dd download completed: \(bytesTransferred) bytes")
    }

    /// Download a file using the original SFTP method as fallback
    private func downloadUsingSFTP(remotePath: String, localURL: URL, progress: @escaping (Double) -> Void) async throws {
        print("Starting SFTP download for \(remotePath)")
        let sftp = try await connectSFTP()
        
        // Open the file for reading on the server
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        
        // Get file attributes to track progress
        let attributes = try await file.readAttributes()
        let totalSize = attributes.size ?? 0
        
        // Create a local file to write to
        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer {
            try? fileHandle.close()
        }
        
        // Read in chunks and write to the local file
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 32768 // 32 KB chunks
        
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            
            let data = try await file.read(from: offset, length: chunkSize)
            if data.readableBytes == 0 {
                break // End of file
            }
            
            // Write the chunk to the local file
            try fileHandle.write(contentsOf: Data(buffer: data))
            
            // Update offset and progress
            offset += UInt64(data.readableBytes)
            if totalSize > 0 {
                progress(Double(offset) / Double(totalSize))
            }
        }
        
        // Close the remote file
        try await file.close()
        print("SFTP download completed: \(offset) bytes")
    }
    
    /// Upload a file to the remote server
    func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Double) -> Void = { _ in }) async throws {
        let sftp = try await connectSFTP()
        
        // Get file size for progress reporting
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        
        // Open the remote file for writing (create if doesn't exist)
        let remoteFile = try await sftp.openFile(
            filePath: remotePath,
            flags: [.write, .create, .truncate]
        )
        
        // Read the local file
        let data = try Data(contentsOf: localURL)
        var offset: UInt64 = 0
        let chunkSize = 32768 // 32 KB chunks
        
        // Upload in chunks
        while offset < data.count {
            if Task.isCancelled {
                throw CancellationError()
            }
            
            let endIndex = min(offset + UInt64(chunkSize), UInt64(data.count))
            let chunkRange = Int(offset)..<Int(endIndex)
            let chunk = data[chunkRange]
            
            // Create ByteBuffer from the chunk
            var buffer = ByteBuffer()
            buffer.writeBytes(chunk)
            
            // Write the chunk to the remote file
            try await remoteFile.write(buffer, at: offset)
            
            // Update offset and progress
            offset = endIndex
            if fileSize > 0 {
                progress(Double(offset) / Double(fileSize))
            }
        }
        
        // Close the remote file
        try await remoteFile.close()
    }
    
    /// Create a directory on the remote server
    func createDirectory(path: String) async throws {
        let sftp = try await connectSFTP()
        try await sftp.createDirectory(atPath: path)
    }
    
    /// Remove a file from the remote server
    func removeFile(path: String) async throws {
        let sftp = try await connectSFTP()
        try await sftp.remove(at: path)
    }
    
    /// Remove a directory from the remote server
    func removeDirectory(path: String) async throws {
        let sftp = try await connectSFTP()
        try await sftp.rmdir(at: path)
    }
    
    /// Rename a file or directory on the remote server
    func rename(oldPath: String, newPath: String) async throws {
        let sftp = try await connectSFTP()
        try await sftp.rename(at: oldPath, to: newPath)
    }
    
    /// Get the attributes of a file on the remote server
    func getFileAttributes(path: String) async throws -> SFTPFileAttributes {
        let sftp = try await connectSFTP()
        return try await sftp.getAttributes(at: path)
    }
    
    // Update the server entity
    func updateServer(_ server: ServerEntity) {
        self.server = server
    }
    
    func disconnect() async {
        let (currentClient, currentSFTP): (SSHClient?, SFTPClient?) = await withCheckedContinuation { continuation in
            connectionLock.lock()
            let currentClient = client
            let currentSFTP = sftpClient
            // Important: Don't set these to nil before closing
            connectionLock.unlock()
            continuation.resume(returning: (currentClient, currentSFTP))
        }
        
        if let sftp = currentSFTP {
            do {
                try await sftp.close()
            } catch {
                print("Error closing SFTP: \(error)")
            }
        }
        
        if let ssh = currentClient {
            do {
                try await ssh.close()
            } catch {
                print("Error closing SSH: \(error)")
            }
        }
        
        // Now that everything is closed, clear the references
        await withCheckedContinuation { continuation in
            connectionLock.lock()
            client = nil
            sftpClient = nil
            connectionLock.unlock()
            continuation.resume()
        }
    }
    
    // Reset the connection state without actually trying to
    // close anything - useful for known broken connections
    func resetState() async {
        await withCheckedContinuation { continuation in
            connectionLock.lock()
            client = nil
            sftpClient = nil
            isConnecting = false
            connectionLock.unlock()
            continuation.resume()
        }
    }
    
    // Force reconnect - useful after app comes back from background
    func forceReconnect() async throws {
        await disconnect()
        // Add delay to allow sockets to fully close
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        try await connect()
    }
    
    deinit {
        // Unregister from the connection manager
        SSHConnectionManager.shared.unregister(connection: self)
        
        Task {
            await disconnect()
        }
    }
}

// Helper function to create an SSH connection from a server entity
func connectSSH(_ server: ServerEntity) async throws -> SSHClient {
    let connection = SSHConnection(server: server)
    try await connection.connect()
    return try await connection.getSSHClient()
}
