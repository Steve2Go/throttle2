import Foundation
import Citadel
import NIOCore

// Singleton manager to track and reset all connections
class SSHConnectionManager {
    static let shared = SSHConnectionManager()
    
    private var activeConnections: [SSHConnection] = []
    private let connectionLock = NSLock()
    
    private init() {}
    
    func register(connection: SSHConnection) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        // Only add if not already in the list
        if !activeConnections.contains(where: { $0 === connection }) {
            activeConnections.append(connection)
        }
    }
    
    func unregister(connection: SSHConnection) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        activeConnections.removeAll(where: { $0 === connection })
    }
    
    func resetAllConnections() async {
        connectionLock.lock()
        let connectionsToReset = activeConnections
        connectionLock.unlock()
        
        for connection in connectionsToReset {
            await connection.disconnect()
            await connection.resetState()
        }
    }
    
    // Call this method when app enters background
    func handleAppBackgrounding() async {
        await resetAllConnections()
    }
    
    // Call this method when app will terminate
    func cleanupBeforeTermination() async {
        await resetAllConnections()
    }
}

// Connection class for both SSH commands and SFTP operations
class SSHConnection {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var client: SSHClient?
    private var sftpClient: SFTPClient?
    private var isConnecting: Bool = false
    private var connectionLock = NSLock()
    private var lastActiveTime: Date = Date()
    
    // Connection timeout (5 minutes of inactivity)
    private let connectionTimeout: TimeInterval = 300
    
    init(host: String, port: Int = 22, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        
        // Register with the connection manager
        SSHConnectionManager.shared.register(connection: self)
    }
    
    func connect() async throws {
        // Use a lock to prevent multiple simultaneous connection attempts
        connectionLock.lock()
        
        // Check if we're already connecting or connected
        if isConnecting {
            connectionLock.unlock()
            
            // Wait a moment and check again if connection succeeded
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            if client != nil {
                return
            } else {
                // Previous connection attempt might still be in progress
                // Wait a bit longer
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                if client != nil {
                    return
                }
            }
            
            // If we still don't have a connection after waiting, start over
            connectionLock.lock()
        }
        
        isConnecting = true
        connectionLock.unlock()
        
        do {
            client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            
            // Update the last active time
            lastActiveTime = Date()
            
            connectionLock.lock()
            isConnecting = false
            connectionLock.unlock()
        } catch {
            connectionLock.lock()
            isConnecting = false
            connectionLock.unlock()
            throw error
        }
    }
    
    // Check if the connection is stale based on timeout
    private func isConnectionStale() -> Bool {
        // If no client exists, it's not stale - it's non-existent
        guard client != nil else { return false }
        
        let currentTime = Date()
        return currentTime.timeIntervalSince(lastActiveTime) > connectionTimeout
    }
    
    // Method to verify and refresh connection if needed
    private func ensureValidConnection() async throws {
        // If connection is stale, disconnect and reconnect
        if isConnectionStale() {
            await disconnect()
            try await connect()
        } else if client == nil {
            try await connect()
        }
        
        // Update last active time
        lastActiveTime = Date()
    }
    
    func executeCommand(_ command: String, maxResponseSize: Int? = nil, mergeStreams: Bool = true) async throws -> (status: Int32, output: String) {
        try await ensureValidConnection()
        
        guard let client = client else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
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
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
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
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
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
        try await ensureValidConnection()
        
        guard let client = client else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        // Update last active time
        lastActiveTime = Date()
        
        // If we already have an SFTP client, return it
        if let sftp = sftpClient, sftp.isActive {
            return sftp
        }
        
        // Create a new SFTP client
        let sftp = try await client.openSFTP()
        sftpClient = sftp
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
    
    /// Download a file from the remote server
    func downloadFile(remotePath: String, localURL: URL, progress: @escaping (Double) -> Void = { _ in }) async throws {
        let sftp = try await connectSFTP()
        
        // Make sure the directory exists
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
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
    
    func disconnect() async {
        connectionLock.lock()
        let currentClient = client
        let currentSFTP = sftpClient
        client = nil
        sftpClient = nil
        connectionLock.unlock()
        
        if let sftp = currentSFTP {
            try? await sftp.close()
        }
        
        if let ssh = currentClient {
            try? await ssh.close()
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
