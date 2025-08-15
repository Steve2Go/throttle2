import Foundation
import Citadel

/// Safe SSH connection helpers that promote create-and-destroy pattern
/// Use these instead of maintaining persistent connection pools
extension SSHConnection {
    
    /// Execute a single SSH command safely
    /// Creates connection, executes command, and cleans up automatically
    static func executeCommand(
        on server: ServerEntity,
        command: String,
        maxResponseSize: Int? = nil
    ) async throws -> (status: Int32, output: String) {
        return try await withConnection(server: server) { connection in
            try await connection.connect()
            return try await connection.executeCommand(command, maxResponseSize: maxResponseSize)
        }
    }
    
    /// Execute multiple SSH commands in sequence safely
    /// Reuses the same connection for efficiency while maintaining safety
    static func executeCommands(
        on server: ServerEntity,
        commands: [String]
    ) async throws -> [(status: Int32, output: String)] {
        return try await withConnection(server: server) { connection in
            try await connection.connect()
            
            var results: [(status: Int32, output: String)] = []
            for command in commands {
                let result = try await connection.executeCommand(command)
                results.append(result)
            }
            return results
        }
    }
    
    /// Download a file safely
    static func downloadFile(
        from server: ServerEntity,
        remotePath: String,
        to localURL: URL,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        try await withConnection(server: server) { connection in
            try await connection.connect()
            try await connection.downloadFile(remotePath: remotePath, localURL: localURL, progress: progress)
        }
    }
    
    /// Upload a file safely
    static func uploadFile(
        to server: ServerEntity,
        from localURL: URL,
        remotePath: String,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        try await withConnection(server: server) { connection in
            try await connection.connect()
            try await connection.uploadFile(localURL: localURL, remotePath: remotePath, progress: progress)
        }
    }
    
    /// List directory contents safely
    static func listDirectory(
        on server: ServerEntity,
        path: String,
        showHidden: Bool = false
    ) async throws -> [FileItem] {
        return try await withConnection(server: server) { connection in
            try await connection.connect()
            return try await connection.listDirectory(path: path, showHidden: showHidden)
        }
    }
    
    /// List directory contents via SFTP safely
    static func listDirectorySFTP(
        on server: ServerEntity,
        path: String
    ) async throws -> [SFTPPathComponent] {
        return try await withConnection(server: server) { connection in
            try await connection.connect()
            return try await connection.listDirectory(path: path)
        }
    }
    
    /// Download file to memory safely
    static func downloadFileToMemory(
        from server: ServerEntity,
        remotePath: String
    ) async throws -> Data {
        return try await withConnection(server: server) { connection in
            try await connection.connect()
            return try await connection.downloadFileToMemory(remotePath: remotePath)
        }
    }
    
    /// Get file attributes safely
    static func getFileAttributes(
        on server: ServerEntity,
        path: String
    ) async throws -> SFTPFileAttributes {
        return try await withConnection(server: server) { connection in
            try await connection.connect()
            return try await connection.getFileAttributes(path: path)
        }
    }
}

/// For cases where you need multiple operations but want to ensure cleanup
/// Usage example:
/// let manager = SafeSSHManager(server: server)
/// defer { await manager.cleanup() }
/// try await manager.connect()
/// // ... perform multiple operations ...
actor SafeSSHManager {
    private let connection: SSHConnection
    private var isConnected = false
    
    init(server: ServerEntity) {
        self.connection = SSHConnection(server: server)
    }
    
    func connect() async throws {
        if !isConnected {
            try await connection.connect()
            isConnected = true
        }
    }
    
    func executeCommand(_ command: String, maxResponseSize: Int? = nil) async throws -> (status: Int32, output: String) {
        guard isConnected else {
            throw SSHTunnelError.tunnelNotConnected
        }
        return try await connection.executeCommand(command, maxResponseSize: maxResponseSize)
    }
    
    func downloadFile(remotePath: String, localURL: URL, progress: @escaping (Double) -> Void = { _ in }) async throws {
        guard isConnected else {
            throw SSHTunnelError.tunnelNotConnected
        }
        try await connection.downloadFile(remotePath: remotePath, localURL: localURL, progress: progress)
    }
    
    func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Double) -> Void = { _ in }) async throws {
        guard isConnected else {
            throw SSHTunnelError.tunnelNotConnected
        }
        try await connection.uploadFile(localURL: localURL, remotePath: remotePath, progress: progress)
    }
    
    func listDirectory(path: String, showHidden: Bool = false) async throws -> [FileItem] {
        guard isConnected else {
            throw SSHTunnelError.tunnelNotConnected
        }
        return try await connection.listDirectory(path: path, showHidden: showHidden)
    }
    
    func cleanup() async {
        if isConnected {
            await connection.disconnect()
            isConnected = false
        }
    }
    
    deinit {
        // Note: Cannot call async cleanup in deinit
        // Users must explicitly call cleanup() or use withConnection
        print("SafeSSHManager deinit - ensure cleanup() was called")
    }
}
