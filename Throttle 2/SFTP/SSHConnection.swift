import Foundation
import Citadel
import NIOCore

// Connection class for both SSH commands and SFTP operations
class SSHConnection {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var client: SSHClient?
    private var sftpClient: SFTPClient?
    
    init(host: String, port: Int = 22, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
    
    func connect() async throws {
        client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }
    
    func executeCommand(_ command: String, maxResponseSize: Int? = nil, mergeStreams: Bool = false) async throws -> (status: Int32, output: String) {
        if client == nil {
            try await connect()
        }
        
        guard let client = client else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        let buffer: ByteBuffer
        if let maxSize = maxResponseSize {
            buffer = try await client.executeCommand(command, maxResponseSize: maxSize, mergeStreams: mergeStreams)
        } else {
            buffer = try await client.executeCommand(command)
        }
        
        let output = String(buffer: buffer)
        return (0, output)
    }
    
    func executeCommandWithStreams(_ command: String) async throws -> ExecCommandStream {
        if client == nil {
            try await connect()
        }
        
        guard let client = client else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        return try await client.executeCommandPair(command)
    }
    
    // MARK: - SFTP Operations
    
    /// Open an SFTP session with the server
    func connectSFTP() async throws -> SFTPClient {
        if client == nil {
            try await connect()
        }
        
        guard let client = client else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
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
        if let sftp = sftpClient {
            try? await sftp.close()
            sftpClient = nil
        }
        
        if let client = client {
            try? await client.close()
            self.client = nil
        }
    }
    
    deinit {
        Task {
            await disconnect()
        }
    }
}
