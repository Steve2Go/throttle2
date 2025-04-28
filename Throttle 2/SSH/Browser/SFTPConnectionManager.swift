import Foundation
import Citadel
import NIO
import KeychainAccess
import SwiftUI

// This class manages SSH and SFTP connections using Citadel
class SFTPConnectionManager {
    // The Citadel SSH client
    private var sshClient: SSHClient?
    // The Citadel SFTP client
    private var sftpClient: SFTPClient?
    
    // Server information
    private let hostname: String
    private let port: Int
    private let username: String
    private let password: String
    private let useKey: Bool
    private let privateKey: String
    private let passphrase: String
    
    // Connection state
    private(set) var isConnected = false
    private(set) var isConnecting = false
    
    init(server: ServerEntity?) {
        guard let server = server else {
            // Default initialization with empty values
            hostname = ""
            port = 22
            username = ""
            password = ""
            useKey = false
            privateKey = ""
            passphrase = ""
            return
        }
        
        // Extract server information
        hostname = server.sftpHost ?? ""
        port = Int(server.sftpPort)
        username = server.sftpUser ?? ""
        useKey = server.sftpUsesKey
        
        // Get credentials from keychain
        @AppStorage("useCloudKit") var useCloudKit: Bool = true
        let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
        
        if useKey {
            privateKey = keychain["sftpKey" + (server.name ?? "")] ?? ""
            passphrase = keychain["sftpPassword" + (server.name ?? "")] ?? ""
            password = ""
        } else {
            password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
            privateKey = ""
            passphrase = ""
        }
    }
    
    // Connect to the SFTP server
    // Connect to the SFTP server
    func connect() async throws {
        guard !isConnected, !isConnecting else {
            return
        }
        
        isConnecting = true
        
        // Connect using Citadel
        let authMethod: SSHAuthenticationMethod
        if useKey {
            // TODO: Implement key-based authentication when available in Citadel
            // For now, use password if available as fallback
            authMethod = .passwordBased(username: username, password: passphrase)
        } else {
            authMethod = .passwordBased(username: username, password: password)
        }
        
        do {
            sshClient = try await SSHClient.connect(
                host: hostname,
                port: port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            
            sftpClient = try await sshClient?.openSFTP()
            isConnected = true
        } catch {
            // Clean up resources in case of error
            try? await disconnect()
            isConnecting = false
            throw error
        }
        
        // Mark as no longer connecting
        isConnecting = false
    }
    
    // Get the SSH client for direct SSH operations
    func getSSHClient() -> SSHClient? {
        return sshClient
    }
    
    // List directory contents
    func contentsOfDirectory(atPath path: String) async throws -> [FileItem] {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        let entries = try await sftp.listDirectory(atPath: path)
        
        return entries.flatMap { name in
            // Map Citadel's results to our FileItem model
            return name.components.compactMap { component in
                // Skip "." and ".." entries
                let filename = component.filename
                if filename == "." || filename == ".." {
                    return nil
                }
                
                let url = URL(fileURLWithPath: path).appendingPathComponent(filename)
                // Check if the directory bit is set in the permissions
                let isDir = component.attributes.permissions != nil &&
                           (component.attributes.permissions! & 0x4000) != 0
                let fileSize = isDir ? nil : Int(component.attributes.size ?? 0)
                
                return FileItem(
                    name: filename,
                    url: url,
                    isDirectory: isDir,
                    size: fileSize,
                    modificationDate: component.attributes.accessModificationTime?.modificationTime ?? Date()
                )
            }
        }
    }
    
    // Create a directory
    func createDirectory(atPath path: String) async throws {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        try await sftp.createDirectory(atPath: path)
    }
    
    // Check if path is a directory
    func isDirectory(atPath path: String) async throws -> Bool {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        let attrs = try await sftp.getAttributes(at: path)
        // Check if the directory bit is set in the permissions
        return attrs.permissions != nil && (attrs.permissions! & 0x4000) != 0
    }
    
    // Get file info
    func infoForFile(atPath path: String) async throws -> (isDirectory: Bool, size: UInt64, mtime: Date) {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        let attrs = try await sftp.getAttributes(at: path)
        return (
            isDirectory: attrs.permissions != nil && (attrs.permissions! & 0x4000) != 0,
            size: attrs.size ?? 0,
            mtime: attrs.accessModificationTime?.modificationTime ?? Date()
        )
    }
    
    // Remove a file
    func removeFile(atPath path: String) async throws {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        try await sftp.remove(at: path)
    }
    
    // Remove a directory
    func removeDirectory(atPath path: String) async throws {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        try await sftp.rmdir(at: path)
    }
    
    // Rename/move a file
    func moveItem(atPath path: String, toPath: String) async throws {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        try await sftp.rename(at: path, to: toPath)
    }
    
    // Download a file to a local URL with progress reporting
    func downloadFile(remotePath: String, localURL: URL, progress: @escaping (Double) -> Bool) async throws {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        // Create the directory if it doesn't exist
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Get file attributes to track progress
        let attrs = try await sftp.getAttributes(at: remotePath)
        let totalSize = attrs.size ?? 0
        
        // Open the file for reading
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        defer {
            Task {
                try? await file.close()
            }
        }
        
        // Remove existing file if needed
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        
        // Create file handle for writing
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: localURL)
        defer {
            try? fileHandle.close()
        }
        
        // Read in chunks and write to the local file
        var offset: UInt64 = 0
        let chunkSize: UInt32 = 32768 // 32 KB chunks
        
        while true {
            // Check if we should continue
            if !progress(Double(offset) / Double(max(totalSize, 1))) {
                throw CancellationError()
            }
            
            let data = try await file.read(from: offset, length: chunkSize)
            if data.readableBytes == 0 {
                break // End of file
            }
            
            // Write the chunk to the local file
            let bytes = Data(buffer: data)
            try fileHandle.write(contentsOf: bytes)
            
            // Update offset
            offset += UInt64(data.readableBytes)
            
            // Report progress
            if totalSize > 0 {
                _ = progress(Double(offset) / Double(totalSize))
            }
        }
        
        // Ensure we report 100% completion
        if totalSize > 0 {
            _ = progress(1.0)
        }
    }
    
    // Upload a file from a local URL with progress reporting
    func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Double) -> Bool) async throws {
        guard let sftp = sftpClient else {
            throw NSError(domain: "SFTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        guard localURL.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "Upload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to access security-scoped resource"])
        }
        
        defer {
            localURL.stopAccessingSecurityScopedResource()
        }
        
        // Get file size for progress reporting
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 1 // Default to 1 to avoid division by zero
        
        // Open the remote file for writing (create if doesn't exist)
        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { remoteFile in
            // Read the local file
            let data: Data
            do {
                data = try Data(contentsOf: localURL)
            } catch {
                throw NSError(domain: "Upload", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to read local file: \(error.localizedDescription)"])
            }
            
            // Upload in chunks
            var offset: UInt64 = 0
            let chunkSize = 32768 // 32 KB chunks
            
            while offset < data.count {
                let endIndex = min(offset + UInt64(chunkSize), UInt64(data.count))
                let chunkRange = Int(offset)..<Int(endIndex)
                let chunk = data[chunkRange]
                
                // Check if we should continue
                if !progress(Double(offset) / Double(fileSize)) {
                    throw CancellationError()
                }
                
                // Create ByteBuffer from the chunk
                var buffer = ByteBuffer()
                buffer.writeBytes(chunk)
                
                // Write the chunk to the remote file
                try await remoteFile.write(buffer, at: offset)
                
                // Update offset
                offset = endIndex
                
                // Report progress
                _ = progress(Double(offset) / Double(fileSize))
            }
            
            // Ensure we report 100% completion
            _ = progress(1.0)
        }
    }
    
    // Disconnect and clean up
    func disconnect() async {
        if let sftp = sftpClient {
            try? await sftp.close()
            sftpClient = nil
        }
        
        if let ssh = sshClient {
            try? await ssh.close()
            sshClient = nil
        }
        
        isConnected = false
    }
    
    deinit {
        // Don't create a strong reference to self
        let sftpClientCopy = sftpClient
        let sshClientCopy = sshClient
        
        // Clear the properties first
        sftpClient = nil
        sshClient = nil
        
        // Then create a task to clean up
        Task {
            if let sftp = sftpClientCopy {
                try? await sftp.close()
            }
            
            if let ssh = sshClientCopy {
                try? await ssh.close()
            }
        }
    }
}

