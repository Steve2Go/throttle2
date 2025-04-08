//
//  CitadelTunnelError.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 3/4/2025.
//


import Foundation
import Citadel
import KeychainAccess

enum CitadelTunnelError: Error {
    case missingCredentials
    case connectionFailed(Error)
    case tunnelSetupFailed(Error)
    case invalidServerConfiguration
}

/// A simple SSH tunnel using Citadel's built-in port forwarding
class CitadelSSHTunnel {
    private let server: ServerEntity
    private let localPort: Int
    private let remoteHost: String
    private let remotePort: Int
    
    private var sshClient: SSHClient?
    private var portForwarding: SSHPortForwarding?
    private var isRunning = false
    
    init(server: ServerEntity, localPort: Int, remoteHost: String, remotePort: Int) {
        self.server = server
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
    
    func start() async throws {
        guard !isRunning else { return }
        
        // Get credentials
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
            throw CitadelTunnelError.missingCredentials
        }
        
        // Validate server configuration
        guard let hostname = server.sftpHost,
              let username = server.sftpUser else {
            throw CitadelTunnelError.invalidServerConfiguration
        }
        
        print("Starting Citadel SSH tunnel: \(hostname):\(server.sftpPort) -> localhost:\(localPort) -> \(remoteHost):\(remotePort)")
        
        do {
            // Connect to the SSH server
            let client = try await SSHClient.connect(
                host: hostname,
                port: Int(server.sftpPort),
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .acceptAnything()
            )
            
            self.sshClient = client
            
            // Create the port forwarding using Citadel's built-in functionality
            let forwarding = try await client.createPortForwarding()
            
            // Set up local to remote forwarding
            try await forwarding.createTunnel(from: .local(port: localPort),
                                             to: .remote(host: remoteHost, port: remotePort))
            
            self.portForwarding = forwarding
            self.isRunning = true
            
            print("SSH tunnel started successfully")
        } catch {
            print("Failed to start SSH tunnel: \(error)")
            // Clean up in case of error
            if let client = self.sshClient {
                try? await client.close()
                self.sshClient = nil
            }
            throw CitadelTunnelError.tunnelSetupFailed(error)
        }
    }
    
    func stop() async {
        guard isRunning else { return }
        
        print("Stopping SSH tunnel")
        isRunning = false
        
        if let forwarding = portForwarding {
            do {
                try await forwarding.close()
            } catch {
                print("Error closing port forwarding: \(error)")
            }
            self.portForwarding = nil
        }
        
        if let client = sshClient {
            do {
                try await client.close()
            } catch {
                print("Error closing SSH client: \(error)")
            }
            self.sshClient = nil
        }
        
        print("SSH tunnel stopped")
    }
    
    func isHealthy() -> Bool {
        return isRunning && sshClient != nil && portForwarding != nil
    }
    
    func recreateIfNeeded() async throws {
        if !isHealthy() {
            print("Tunnel is unhealthy, recreating...")
            await stop()
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            try await start()
        }
    }
}

/// Manager for CitadelSSHTunnel instances
class CitadelTunnelManager {
    static let shared = CitadelTunnelManager()
    
    private var tunnels: [String: CitadelSSHTunnel] = [:]
    private let tunnelLock = NSLock()
    
    private init() {}
    
    func getTunnel(withIdentifier identifier: String) -> CitadelSSHTunnel? {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        return tunnels[identifier]
    }
    
    func storeTunnel(_ tunnel: CitadelSSHTunnel, withIdentifier identifier: String) {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        tunnels[identifier] = tunnel
    }
    
    func removeTunnel(withIdentifier identifier: String) {
        tunnelLock.lock()
        let tunnel = tunnels.removeValue(forKey: identifier)
        tunnelLock.unlock()
        
        if let tunnel = tunnel {
            Task {
                await tunnel.stop()
            }
        }
    }
    
    func ensureTunnelHealth(withIdentifier identifier: String) async throws {
        guard let tunnel = getTunnel(withIdentifier: identifier) else {
            return
        }
        try await tunnel.recreateIfNeeded()
    }
    
    func ensureAllTunnelsHealth() async {
        tunnelLock.lock()
        let tunnelsToCheck = tunnels
        tunnelLock.unlock()
        
        for (identifier, tunnel) in tunnelsToCheck {
            do {
                try await tunnel.recreateIfNeeded()
            } catch {
                print("Failed to recreate tunnel \(identifier): \(error)")
            }
        }
    }
    
    func tearDownAllTunnels() {
        tunnelLock.lock()
        let tunnelsToStop = tunnels
        tunnels.removeAll()
        tunnelLock.unlock()
        
        Task {
            for (_, tunnel) in tunnelsToStop {
                await tunnel.stop()
            }
        }
    }
}

/// Helper function to create a tunnel
func setupCitadelTunnel(_ server: ServerEntity, localPort: Int, remoteHost: String, remotePort: Int, identifier: String) async throws -> CitadelSSHTunnel {
    // First, tear down any existing tunnel with this identifier
    CitadelTunnelManager.shared.removeTunnel(withIdentifier: identifier)
    
    print("Setting up Citadel tunnel: \(identifier) on localhost:\(localPort) -> \(remoteHost):\(remotePort)")
    
    // Create and start a new tunnel
    let tunnel = CitadelSSHTunnel(
        server: server,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort
    )
    
    try await tunnel.start()
    
    // Store the tunnel for later access
    CitadelTunnelManager.shared.storeTunnel(tunnel, withIdentifier: identifier)
    
    return tunnel
}