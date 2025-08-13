import Foundation
import Citadel
import NIOCore
import KeychainAccess
import NIOSSH
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
    /**
     Usage:
     try await SSHConnection.withConnection(server: server) { connection in
         // ... use connection ...
     }
     This ensures the connection is always disconnected at all exit points.
     */
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
        // [Lock handling code remains the same...]
        
        do {
            // Get authentication method
            let authMethod: SSHAuthenticationMethod
            
            if server.sftpUsesKey {
                print("Using key authentication for \(server.sftpHost ?? "")")
                // Let the key manager handle authentication
                authMethod = try SSHKeyManager.shared.getAuthenticationMethod(for: server)
            } else {
                print("Using password authentication for \(server.sftpHost ?? "")")
                let keychain = Keychain(service: "srgim.throttle2")
                    .synchronizable(true)
                
                guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
                    throw SSHTunnelError.missingCredentials
                }
                
                authMethod = .passwordBased(username: server.sftpUser ?? "", password: password)
            }
            
            // Set up algorithms to increase compatibility with older servers
            var algorithms = SSHAlgorithms()
            algorithms.transportProtectionSchemes = .add([
                AES128CTR.self
            ])
            algorithms.keyExchangeAlgorithms = .add([
                DiffieHellmanGroup14Sha1.self,
                DiffieHellmanGroup14Sha256.self
            ])
            
            // Connect to SSH server
            client = try await SSHClient.connect(
                host: server.sftpHost ?? "",
                port: Int(server.sftpPort),
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                algorithms: algorithms,
                protocolOptions: [
                    .maximumPacketSize(1 << 20)  // Increase max packet size
                ]
            )
            
            print("SSH connection established successfully to \(server.sftpHost ?? "")")
            
            // Update last active time
            lastActiveTime = Date()
            
            await withCheckedContinuation { [weak self] continuation in
                self?.connectionLock.lock()
                self?.isConnecting = false
                self?.connectionLock.unlock()
                continuation.resume()
            }
        } catch let error as NIOSSHError {
            await resetConnectionState()
            ToastManager.shared.show(message: "SSH connection failed with NIOSSHError: \(error)", icon: "exclamationmark.triangle", color: Color.red)
            print("SSH connection failed with NIOSSHError: \(error)")
            throw SSHTunnelError.connectionFailed(error)
        } catch {
            await resetConnectionState()
            print("SSH connection failed with error: \(error)")
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
    
    // Helper to reset connection state on failure
    private func resetConnectionState() async {
        await withCheckedContinuation { [weak self] continuation in
            self?.connectionLock.lock()
            self?.client = nil
            self?.sftpClient = nil
            self?.isConnecting = false
            self?.connectionLock.unlock()
            continuation.resume()
        }
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
        await withCheckedContinuation { [weak self] continuation in
            self?.connectionLock.lock()
            self?.lastActiveTime = Date()
            self?.connectionLock.unlock()
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
               // let url = URL(fileURLWithPath: "file://" + fullPath) ?? URL(fileURLWithPath: fullPath)
                let url =  URL(fileURLWithPath: fullPath)
                
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
    
    func executeInteractiveCommand(_ command: String) async throws -> ExecCommandStream {
            try await ensureValidConnection()
            
            guard let client = client else {
                throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
            }
            
            // Update last active time
            lastActiveTime = Date()
            
            // For interactive commands, we use executeCommandPair which gives us
            // direct access to stdin/stdout streams
            return try await client.executeCommandPair(command)
        }
        
        /// Helper method to execute a command and get binary data directly
        func executeCommandForData(_ command: String, maxSize: Int = 1024 * 1024 * 10) async throws -> Data {
            // Ensure we have a valid SSH client
            let sshClient = try await getSSHClient()
            // Execute the command and retrieve raw bytes
            let byteBuffer = try await sshClient.executeCommand(command, maxResponseSize: maxSize, mergeStreams: true)
            return Data(buffer: byteBuffer)
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
    
    /// Download a file from the remote server using SFTP
    func downloadFile(remotePath: String, localURL: URL, progress: @escaping (Double) -> Void = { _ in }) async throws {
        print("Starting SFTP download for \(remotePath)")
        
        // Make sure the directory exists before attempting any download
        let directory = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Create empty file to ensure it exists and is writable
        if !FileManager.default.fileExists(atPath: localURL.path) {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
        }
        
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
        let (currentClient, currentSFTP): (SSHClient?, SFTPClient?) = await withCheckedContinuation { [weak self] continuation in
            self?.connectionLock.lock()
            let currentClient = self?.client
            let currentSFTP = self?.sftpClient
            self?.connectionLock.unlock()
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
        await withCheckedContinuation { [weak self] continuation in
            self?.connectionLock.lock()
            self?.client = nil
            self?.sftpClient = nil
            self?.connectionLock.unlock()
            continuation.resume()
        }
    }
    
    // Reset the connection state without actually trying to
    // close anything - useful for known broken connections
    func resetState() async {
        await withCheckedContinuation { [weak self] continuation in
            self?.connectionLock.lock()
            self?.client = nil
            self?.sftpClient = nil
            self?.isConnecting = false
            self?.connectionLock.unlock()
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
    
    /// Helper to run an async operation with automatic disconnect at all exit points.
    static func withConnection<T>(
        server: ServerEntity,
        operation: @escaping (SSHConnection) async throws -> T
    ) async throws -> T {
        let connection = SSHConnection(server: server)
        do {
            let result = try await operation(connection)
            await connection.disconnect()
            return result
        } catch {
            await connection.disconnect()
            throw error
        }
    }
    
     deinit {
         // Unregister from the connection manager
         do{
             SSHConnectionManager.shared.unregister(connection: self)
         }
         
         // Do not launch a Task here; let the connection be cleaned up elsewhere
     }
    
    // Helper to check if SFTP attributes indicate a directory
    static func isDirectory(attributes: SFTPFileAttributes) -> Bool {
        if let perms = attributes.permissions {
            return (perms & 0x4000) != 0
        }
        return false
    }
}

// Helper function to create an SSH connection from a server entity
func connectSSH(_ server: ServerEntity) async throws -> SSHClient {
    let connection = SSHConnection(server: server)
    try await connection.connect()
    return try await connection.getSSHClient()
}
