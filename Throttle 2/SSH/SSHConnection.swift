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
        
        // Clear global semaphore when resetting all connections
        await GlobalConnectionSemaphore.shared.clearSemaphore()
        
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
// RECOMMENDED USAGE: Always use SSHConnection.withConnection() for safety
class SSHConnection {
    /**
     SAFE Usage Pattern:
     try await SSHConnection.withConnection(server: server) { connection in
         // ... use connection ...
     }
     This ensures the connection is always disconnected at all exit points.
     
     AVOID: Creating persistent SSHConnection instances that are reused.
     */
    private var server: ServerEntity
    private var client: SSHClient?
    private var sftpClient: SFTPClient?
    private var isConnecting: Bool = false
    private var connectionLock = NSLock()
    
    // Remove connection timeout and reuse logic - connections should be short-lived
    
    init(server: ServerEntity) {
        self.server = server
        // Remove automatic registration with connection manager for short-lived connections
    }
    
    func connect() async throws {
        // Simplified connection logic without complex state management
        connectionLock.lock()
        if isConnecting {
            connectionLock.unlock()
            // Wait for connection to complete, but don't wait indefinitely
            for _ in 0..<50 { // Wait up to 5 seconds
                try? await Task.sleep(nanoseconds: 100_000_000)
                connectionLock.lock()
                let stillConnecting = isConnecting
                connectionLock.unlock()
                if !stillConnecting { break }
            }
            return
        }
        
        if client != nil {
            connectionLock.unlock()
            return // Already connected
        }
        
        isConnecting = true
        connectionLock.unlock()
        
        do {
            // Get authentication method
            let authMethod: SSHAuthenticationMethod
            
            if server.sftpUsesKey {
                authMethod = try SSHKeyManager.shared.getAuthenticationMethod(for: server)
            } else {
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
            let newClient = try await SSHClient.connect(
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
            
            // Set the client only after successful connection
            connectionLock.lock()
            client = newClient
            isConnecting = false
            connectionLock.unlock()
            
            print("SSH connection established successfully to \(server.sftpHost ?? "")")
            
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

    // Helper to reset connection state on failure
    private func resetConnectionState() async {
        connectionLock.lock()
        client = nil
        sftpClient = nil
        isConnecting = false
        connectionLock.unlock()
    }
    
    // Simplified method to get the client directly - no automatic reconnection
    func getSSHClient() async throws -> SSHClient {
        connectionLock.lock()
        let currentClient = client
        connectionLock.unlock()
        
        guard let client = currentClient else {
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected - call connect() first"]))
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
        let client = try await getSSHClient()
        
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
        let client = try await getSSHClient()
        
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
        let client = try await getSSHClient()
        return try await client.executeCommandPair(command)
    }
    

    
    // MARK: - SFTP Operations
    
    /// Open an SFTP session with the server
    func connectSFTP() async throws -> SFTPClient {
        let client = try await getSSHClient()
        
        // If we already have an SFTP client, try to use it but verify it's still active
        connectionLock.lock()
        let currentSFTP = sftpClient
        connectionLock.unlock()
        
        if let sftp = currentSFTP, sftp.isActive {
            // Verify the SFTP connection is still valid with a simple operation
            do {
                _ = try await sftp.listDirectory(atPath: ".")
                return sftp
            } catch {
                // SFTP connection is no longer valid, create a new one
                print("Existing SFTP connection is invalid, creating new one. Error: \(error)")
                connectionLock.lock()
                sftpClient = nil
                connectionLock.unlock()
            }
        }
        
        // Create a new SFTP client
        let sftp = try await client.openSFTP()
        connectionLock.lock()
        sftpClient = sftp
        connectionLock.unlock()
        return sftp
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
    
    /// Download a file content to memory as Data
    func downloadFileToMemory(remotePath: String) async throws -> Data {
        let sftp = try await connectSFTP()
        
        // Open the file for reading
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        defer {
            Task { try? await file.close() }
        }
        
        // Get file size
        let attributes = try await file.readAttributes()
        let totalSize = attributes.size ?? 0
        
        // Read the entire file into memory
        var fileData = Data()
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
            
            // Append the chunk to our data
            fileData.append(Data(buffer: data))
            offset += UInt64(data.readableBytes)
        }
        
        return fileData
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
        connectionLock.lock()
        let currentClient = client
        let currentSFTP = sftpClient
        client = nil
        sftpClient = nil
        connectionLock.unlock()
        
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
    }
    
    // Reset the connection state without actually trying to
    // close anything - useful for known broken connections
    func resetState() async {
        connectionLock.lock()
        client = nil
        sftpClient = nil
        isConnecting = false
        connectionLock.unlock()
    }
    
    // Force reconnect - useful after app comes back from background
    func forceReconnect() async throws {
        await disconnect()
        // Add delay to allow sockets to fully close
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        try await connect()
    }
    
    /// Helper to run an async operation with automatic disconnect at all exit points.
    static func withConnection<T>(
        server: ServerEntity,
        operation: @escaping (SSHConnection) async throws -> T
    ) async throws -> T {
        // Acquire global connection semaphore
        await GlobalConnectionSemaphore.shared.acquireConnection()
        
        let connection = SSHConnection(server: server)
        do {
            let result = try await operation(connection)
            await connection.disconnect()
            // Release semaphore after successful operation
            await GlobalConnectionSemaphore.shared.releaseConnection()
            return result
        } catch {
            await connection.disconnect()
            // Release semaphore after failed operation
            await GlobalConnectionSemaphore.shared.releaseConnection()
            throw error
        }
    }
    
     deinit {
         // Simple cleanup without launching async tasks
         // The connection manager will handle cleanup elsewhere
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
