import Foundation
import Citadel
import Crypto
import KeychainAccess
import NIOSSH
import SwiftUI

/// A manager class for handling SSH key authentication
class SSHKeyManager {
    static let shared = SSHKeyManager()

    // Keychain service constants
    private let keychainService = "srgim.throttle2"
    //private let keychainAccessGroup = "group.com.srgim.Throttle-2"
    
    private init() {}
    
    /// Get the SSH authentication method for a server
    /// - Parameter server: The server entity to authenticate with
    /// - Returns: An appropriate SSHAuthenticationMethod
    func getAuthenticationMethod(for server: ServerEntity) throws -> SSHAuthenticationMethod {
        guard let username = server.sftpUser, !username.isEmpty else {
            throw SSHTunnelError.missingCredentials
        }
        
        // Get the keychain
        let keychain = getKeychain()
        
        // If not using key authentication, return password-based authentication
        if !server.sftpUsesKey {
            guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
                throw SSHTunnelError.missingCredentials
            }
            return .passwordBased(username: username, password: password)
        }
        
        // Get the SSH key content
        let keyId = "sftpKey" + (server.name ?? "")
        guard let keyContent = keychain[keyId] else {
            throw SSHTunnelError.missingCredentials
        }
        
        // Get the passphrase if one exists
        let passphrase = keychain["sftpPhrase" + (server.name ?? "")]
        
        // Parse the key content based on its format
        return try parseKeyAndCreateAuth(keyContent: keyContent, passphrase: passphrase, username: username)
    }
    
    /// Store an SSH key in the keychain for a server
    /// - Parameters:
    ///   - keyContent: The raw SSH key content
    ///   - serverName: The name of the server
    func storeKey(_ keyContent: String, for serverName: String) throws {
        let keychain = getKeychain()
        let keyId = "sftpKey" + serverName
        
        try keychain.set(keyContent, key: keyId)
        print("SSH key stored in keychain for server: \(serverName)")
    }
    
    /// Store a passphrase for an SSH key
    /// - Parameters:
    ///   - passphrase: The passphrase for the key
    ///   - serverName: The name of the server
    func storePassphrase(_ passphrase: String, for serverName: String) throws {
        if passphrase.isEmpty {
            return
        }
        
        let keychain = getKeychain()
        let passphraseId = "sftpPhrase" + serverName
        try keychain.set(passphrase, key: passphraseId)
    }
    
    /// Remove stored keys for a server
    /// - Parameter serverName: The name of the server
    func removeKeysFor(serverName: String) {
        let keychain = getKeychain()
        keychain["sftpKey" + serverName] = nil
        keychain["sftpPhrase" + serverName] = nil
    }
    
    // MARK: - Private methods
    
    private func getKeychain() -> Keychain {
        // Check if CloudKit is enabled
        let useCloudKit = UserDefaults.standard.bool(forKey: "useCloudKit")
        return Keychain(service: keychainService)
            .synchronizable(useCloudKit)
    }
    
    /// Parse SSH key content and create an appropriate authentication method
    private func parseKeyAndCreateAuth(keyContent: String, passphrase: String?, username: String) throws -> SSHAuthenticationMethod {
        // Prepare decryption key if passphrase is provided
        let decryptionKey: Data? = passphrase?.data(using: .utf8)
        
        // Try to parse as ED25519 key
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyContent, decryptionKey: decryptionKey)
            return .ed25519(username: username, privateKey: privateKey)
        } catch {
            print("Not an ED25519 key, trying RSA...")
        }
        
        // Try to parse as RSA key
        do {
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyContent, decryptionKey: decryptionKey)
            return .rsa(username: username, privateKey: privateKey)
        } catch {
            print("Not an RSA key, error: \(error)")
        }
        
        // Try other key types if they're supported by your version of Citadel
        // e.g. P256, P384, P521
        ToastManager.shared.show(message: "SSH Key Error - RSA and ED25519 supported only.", icon: "exclamationmark.triangle", color: Color.red)
        throw SSHTunnelError.invalidServerConfiguration
    }
}
