//
//  SSHTunnelClass.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 2/4/2025.
//
import SwiftUI
import KeychainAccess
import Network

// created to unclutter the main app
extension Throttle_2App {
    
    func refeshTunnel(store: Store, torrentManager: TorrentManager){
        
      //  ThumbnailLoader.shared.deactivate()
        TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
      // TunnelManagerHolder.shared.removeTunnel(withIdentifier: "http-streamer")
        guard let server = store.selection else {return}
        
        let isTunnel = server.sftpRpc
        #if os(iOS)
        if server.sftpUsesKey == true {
            Task{
                //sftp tunnel
                let sftp = try SSHTunnelManager(server: server, localPort: 2222, remoteHost: "127.0.0.1", remotePort: Int(server.sftpPort))
                try await sftp.start()
                TunnelManagerHolder.shared.storeTunnel(sftp, withIdentifier: "sftp")
            }
        }
        #endif
        
        
        if isTunnel {
            let localport = 4000 // update after tunnel logic
            let port  = server.port
            
            Task{
                await SSHConnectionManager.shared.resetAllConnections()
                let tmanager = try SSHTunnelManager(server: server, localPort: localport, remoteHost: "127.0.0.1", remotePort: Int(port))
                try await tmanager.start()
                TunnelManagerHolder.shared.storeTunnel(tmanager, withIdentifier: "transmission-rpc")
                torrentManager.startPeriodicUpdates()
                
                
                
                if !store.magnetLink.isEmpty || store.selectedFile != nil {
                    presenting.activeSheet = "adding"
                }
            }
        } else{
            if !store.magnetLink.isEmpty || store.selectedFile != nil {
                presenting.activeSheet = "adding"
            }
        }
        
    }
    
    func setupServer (store: Store, torrentManager: TorrentManager) {
    
        // Reset all SSH connections
        Task{
            await SSHConnectionManager.shared.resetAllConnections()
        }
            store.selectedTorrentId = nil
            
            if store.selection != nil {
                
                
                
                // load the keychain
                @AppStorage("useCloudKit") var useCloudKit: Bool = true
                let keychain = useCloudKit ? Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true) : Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(false)
                let server = store.selection
                
                // trying to keep it as clear as possible
                let proto = (server?.protoHttps ?? false) ? "https" : "http"
                let domain = server?.url ?? "127.0.0.1"
                let user = server?.sftpUser ?? ""
                let password = keychain["password" + (server?.name! ?? "")] ?? ""
                
                let port  = server?.port ?? 9091
                let path = server?.rpc ?? "transmission/rpc"
                
                let isTunnel = server?.sftpRpc ?? false
                //let hasKey = server?.sftpUsesKey
                let localport = 4000 // update after tunnel logic
                
                var url = ""
                var at = ""
                
#if os(iOS)
                if server?.sftpUsesKey == true {
                    Task{
                        //sftp tunnel
                        let sftp = try SSHTunnelManager(server: server!, localPort: 2222, remoteHost: "127.0.0.1", remotePort: Int(server!.sftpPort))
                        try await sftp.start()
                        TunnelManagerHolder.shared.storeTunnel(sftp, withIdentifier: "sftp")
                        
                        //try await checkAndEnableLocalPasswordAuth(server: server!)
                    }
                }
                #endif
                if isTunnel{
                    TunnelManagerHolder.shared.removeTunnel(withIdentifier: "transmission-rpc")
                    //server tunnel creation
                    if let server = server {
                        Task {
                            do {
                                let tmanager = try SSHTunnelManager(server: server, localPort: localport, remoteHost: "127.0.0.1", remotePort: Int(port))
                                try await tmanager.start()
                                TunnelManagerHolder.shared.storeTunnel(tmanager, withIdentifier: "transmission-rpc")
                                //
                                //Now build the rpc url
                                
                                url += "http://"
                                if !user.isEmpty {
                                    at = "@"
                                    url += user
                                    if !password.isEmpty {
                                        url += ":\(password)"
                                    }
                                }
                                url += "\(at)127.0.0.1:\(String(localport))\(path)"
                                
                                store.connectTransmission = url
                                ServerManager.shared.setServer(store.selection!)
                                torrentManager.isLoading = true
                                
                                torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                                try await torrentManager.fetchUpdates(fullFetch: true)
                                torrentManager.startPeriodicUpdates()
                                try await Task.sleep(for: .milliseconds(500))
                                if !store.magnetLink.isEmpty || store.selectedFile != nil {
                                    presenting.activeSheet = "adding"
                                }
                            } catch let error as SSHTunnelError {
                                
                                print("An unexpected error occurred: \(error)")
                            }
                        }
                    }
                    
                    isTunneling = false
                }  else {
                    // just build the url
                    
                    url += "\(proto)://"
                    if !user.isEmpty {
                        at = "@"
                        url += user
                        if !password.isEmpty {
                            url += ":\(password)"
                        }
                    }
                    url += "\(at)\(domain):\(String(port))\(path)"
                    store.connectTransmission = url
                    ServerManager.shared.setServer(store.selection!)
                    torrentManager.isLoading = true
                    torrentManager.updateBaseURL(URL( string: store.connectTransmission)!)
                    torrentManager.reset()
                    Task {
                        try await torrentManager.fetchUpdates(fullFetch: true)
                        torrentManager.startPeriodicUpdates()
                        try await Task.sleep(for: .milliseconds(500))
                        if !store.magnetLink.isEmpty || store.selectedFile != nil {
                            presenting.activeSheet = "adding"
                        }
                    }
                    
                }

            }
    }
    #if os(iOS)
    func setupExternalDisplayManager() {
           // This will start monitoring for external displays and create a black screen when needed
           ExternalDisplayManager.shared.startMonitoring()
       }
    // In Throttle_2App.swift, add this near your setupServer function:

    
    #endif
}


class NetworkMonitor: ObservableObject {
    private let networkMonitor = NWPathMonitor()
    private let workerQueue = DispatchQueue(label: "Monitor")
    var isConnected = false
    var isExpensive = false
    var gateways: [NWEndpoint] = []

    init() {
        networkMonitor.pathUpdateHandler = { path in
            self.isConnected = path.status == .satisfied
            self.isExpensive = path.isExpensive
            self.gateways = path.gateways
            Task {
                await MainActor.run {
                    self.objectWillChange.send()
                }
            }
        }
        networkMonitor.start(queue: workerQueue)
    }
}


/// Helper function to check and enable local password authentication
func checkAndEnableLocalPasswordAuth(server: ServerEntity) async throws {
    // Get SSH connection to the server using key authentication
    let client = try await ServerManager.shared.connectSSH(server)
    
    // Get sudo password from keychain
    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
        print("Cannot configure local password auth: Missing password")
        return
    }
    
    // Check current sshd configuration for localhost password auth
    let checkCmd = "grep -E 'Match Address 127.0.0.1|PasswordAuthentication' /etc/ssh/sshd_config || echo 'Not configured'"
    let checkResult = try await client.executeCommand(checkCmd)
    let checkOutput = String(buffer: checkResult).trimmingCharacters(in: .whitespacesAndNewlines)
    
    // If not properly configured, try to modify sshd_config with sudo
    if !checkOutput.contains("Match Address 127.0.0.1") || !checkOutput.contains("PasswordAuthentication yes") {
        print("Local password authentication not configured. Attempting to configure...")
        
        // Create backup of sshd_config with piped sudo password
        let backupCmd = "echo '\(password)' | sudo -S cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak"
        _ = try await client.executeCommand(backupCmd)
        
        // Append necessary configuration
        let configLines = """
        
        # Added by Throttle for secure local tunnel access
        Match Address 127.0.0.1
            PasswordAuthentication yes
        """
        
        let appendCmd = """
        echo '\(password)' | sudo -S bash -c 'echo "\(configLines)" >> /etc/ssh/sshd_config'
        """
        
        let appendResult = try await client.executeCommand(appendCmd)
        
        // Verify the changes
        let verifyCmd = "grep -E 'Match Address 127.0.0.1|PasswordAuthentication' /etc/ssh/sshd_config"
        let verifyResult = try await client.executeCommand(verifyCmd)
        let verifyOutput = String(buffer: verifyResult).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if verifyOutput.contains("Match Address 127.0.0.1") && verifyOutput.contains("PasswordAuthentication yes") {
            // Restart SSH service to apply changes with piped sudo password
            let restartCmd = """
            echo '\(password)' | sudo -S systemctl restart sshd 2>/dev/null || 
            echo '\(password)' | sudo -S service ssh restart 2>/dev/null || 
            echo '\(password)' | sudo -S /etc/init.d/ssh restart 2>/dev/null
            """
            _ = try await client.executeCommand(restartCmd)
            print("Successfully configured local password authentication")
        } else {
            print("Failed to configure local password authentication. VLC streaming may not work properly.")
        }
    } else {
        print("Local password authentication already configured")
    }
}
