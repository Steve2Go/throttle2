//
//  SSHFSKeyHandler.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 28/4/2025.
//

#if os(macOS)
import Foundation
import KeychainAccess
import Citadel
import Crypto

/// Handler for managing SSH keys with sshfs on macOS
class SSHFSKeyHandler {
    static let shared = SSHFSKeyHandler()
    private var temporaryKeyFiles: [String] = []
    
    private init() {}
    
    /// Prepares SSH key for sshfs mounting using ssh-agent
    /// Returns: Whether the key was successfully added to ssh-agent
    @discardableResult
    func addKeyToSSHAgent(server: ServerEntity) throws -> Bool {
        guard server.sftpUsesKey else {
            return false  // Not using key authentication
        }
        
        // Get key content from SSHKeyManager's keychain
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
            .synchronizable(UserDefaults.standard.bool(forKey: "useCloudKit"))
        
        guard let keyContent = keychain["sftpKey" + (server.name ?? "")] else {
            throw SSHTunnelError.missingCredentials
        }
        
        // Create temporary key file
        let tempDir = FileManager.default.temporaryDirectory
        let keyFileName = "sshfs_key_\(UUID().uuidString)"
        let keyPath = tempDir.appendingPathComponent(keyFileName)
        
        // Write key to temporary file with restricted permissions
        try keyContent.write(to: keyPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
        
        // Track temporary file for cleanup
        temporaryKeyFiles.append(keyPath.path)
        
        // Check if key has a passphrase
        let passphrase = keychain["sftpPhrase" + (server.name ?? "")]
        
        // Add key to ssh-agent using expect script if passphrase is needed
        if let passphrase = passphrase, !passphrase.isEmpty {
            let expectScript = """
            #!/usr/bin/expect -f
            spawn ssh-add \(keyPath.path)
            expect "Enter passphrase"
            send "\(passphrase)\\r"
            expect eof
            """
            
            let expectPath = tempDir.appendingPathComponent("expect_\(UUID().uuidString).sh")
            try expectScript.write(to: expectPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: expectPath.path)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = [expectPath.path]
            
            try process.run()
            process.waitUntilExit()
            
            // Clean up expect script
            try? FileManager.default.removeItem(at: expectPath)
        } else {
            // No passphrase needed, add directly
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            process.arguments = [keyPath.path]
            
            try process.run()
            process.waitUntilExit()
        }
        
        return true
    }
    
    /// Clean up all temporary key files
    func cleanupAllTemporaryKeys() {
        for keyPath in temporaryKeyFiles {
            try? FileManager.default.removeItem(atPath: keyPath)
        }
        temporaryKeyFiles.removeAll()
    }
    
    /// Modify sshfs command to use ssh-agent or password
    func modifySSHFSCommand(baseCommand: String, server: ServerEntity) throws -> String {
        var modifiedCommand = baseCommand
        
        // Always accept any host key for consistency with iOS
        modifiedCommand += " -o StrictHostKeyChecking=no"
        modifiedCommand += " -o UserKnownHostsFile=/dev/null"
        
        if server.sftpUsesKey {
            // Ensure key is added to ssh-agent
            try addKeyToSSHAgent(server: server)
            
            // Use ssh-agent for authentication
            modifiedCommand += " -o PreferredAuthentications=publickey"
            modifiedCommand += " -o IdentityAgent=\(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "")"
        } else {
            // For password authentication, use sshpass
            let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
                .synchronizable(UserDefaults.standard.bool(forKey: "useCloudKit"))
            
            if let password = keychain["sftpPassword" + (server.name ?? "")] {
                return "sshpass -p '\(password)' \(modifiedCommand)"
            }
        }
        
        return modifiedCommand
    }
}

// Extension to handle sshfs mounting with key authentication
extension ServerManager {
    func mountSSHFS(_ server: ServerEntity, mountPoint: String) async throws {
        guard let sftpHost = server.sftpHost,
              let sftpUser = server.sftpUser,
              let pathServer = server.pathServer else {
            throw SSHTunnelError.invalidServerConfiguration
        }
        
        // Create mount point if it doesn't exist
        try FileManager.default.createDirectory(atPath: mountPoint, 
                                              withIntermediateDirectories: true)
        
        // Base sshfs command with additional options for stability
        let baseCommand = """
        sshfs \(sftpUser)@\(sftpHost):\(pathServer) \(mountPoint) \
        -p \(server.sftpPort) \
        -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
        -o allow_other,default_permissions \
        -o auto_cache,cache=yes \
        -o kernel_cache,compression=no \
        -o noappledouble,noapplexattr
        """
        
        // Modify command based on authentication method
        let finalCommand = try SSHFSKeyHandler.shared.modifySSHFSCommand(baseCommand: baseCommand, server: server)
        
        // Execute the command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", finalCommand]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            
            // Clean up temporary files if mount failed
            SSHFSKeyHandler.shared.cleanupAllTemporaryKeys()
            
            throw SSHTunnelError.connectionFailed(NSError(domain: "SSHFS", code: Int(process.terminationStatus), 
                                                         userInfo: [NSLocalizedDescriptionKey: errorString]))
        }
        
        print("Successfully mounted SSHFS at \(mountPoint)")
    }
    
    func unmountSSHFS(mountPoint: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/umount")
        process.arguments = [mountPoint]
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            // Try with diskutil if umount fails
            let diskutilProcess = Process()
            diskutilProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            diskutilProcess.arguments = ["unmount", "force", mountPoint]
            
            try diskutilProcess.run()
            diskutilProcess.waitUntilExit()
        }
        
        // Clean up any temporary key files
        SSHFSKeyHandler.shared.cleanupAllTemporaryKeys()
    }
}
#endif
