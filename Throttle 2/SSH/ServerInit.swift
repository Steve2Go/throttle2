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
        TunnelManagerHolder.shared.removeTunnel(withIdentifier: "sftp")
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
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    presenting.activeSheet = "adding"
                }
            }
        } else{
            if !store.magnetLink.isEmpty || store.selectedFile != nil {
                Task{
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    presenting.activeSheet = "adding"
                }
            }
            torrentManager.startPeriodicUpdates()
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
                        
                        try await checkAndEnableLocalPasswordAuth(server: server!)
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
    // Get sudo password from keychain
    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
        print("No password saved - skipping local password auth configuration")
        return
    }
    
    // Get SSH connection to the server using key authentication
    let client = try await ServerManager.shared.connectSSH(server)
    
    // First, try connecting with password to localhost to see if it already works
    let testPasswordAuthCmd = """
    sshpass -p '\(password)' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \(server.sftpUser ?? "")@127.0.0.1 echo 'success' 2>&1 || echo 'failed'
    """
    let testResult = try await client.executeCommand(testPasswordAuthCmd)
    let testOutput = String(buffer: testResult).trimmingCharacters(in: .whitespacesAndNewlines)
    
    if testOutput.contains("success") {
        print("Local password authentication already works - no changes needed")
        return
    }
    
    // Check if sshpass is installed (needed for testing)
    let sshpassCheckCmd = "which sshpass || echo 'not found'"
    let sshpassResult = try await client.executeCommand(sshpassCheckCmd)
    let sshpassOutput = String(buffer: sshpassResult).trimmingCharacters(in: .whitespacesAndNewlines)
    
    if sshpassOutput.contains("not found") {
        print("Warning: sshpass not installed, cannot test password auth")
    }
    
    // Step 1: Check global password authentication status
    let globalCheckCmd = """
    grep -Ei '^[[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)' /etc/ssh/sshd_config | tail -1 || echo 'Not configured'
    """
    let globalResult = try await client.executeCommand(globalCheckCmd)
    let globalOutput = String(buffer: globalResult).trimmingCharacters(in: .whitespacesAndNewlines)
    
    let isGlobalPasswordAuthDisabled = globalOutput.lowercased().contains("passwordauthentication no")
    print("Global password auth status: \(isGlobalPasswordAuthDisabled ? "disabled" : "enabled/not configured")")
    
    // If password auth is not disabled globally, the issue might be elsewhere (e.g., PAM, SELinux, etc.)
    if !isGlobalPasswordAuthDisabled {
        print("Password auth is not disabled globally, but still not working. May need to check PAM, SELinux, or other auth settings.")
        // You might want to add checks for other possible issues here
        return
    }
    
    // Step 2: Check if there's already a Match block for localhost
    let localhostCheckCmd = """
    sed -n '/Match Address 127\\.0\\.0\\.1/,/Match\\|$/p' /etc/ssh/sshd_config | grep -i PasswordAuthentication || echo 'Not configured'
    """
    let localhostResult = try await client.executeCommand(localhostCheckCmd)
    let localhostOutput = String(buffer: localhostResult).trimmingCharacters(in: .whitespacesAndNewlines)
    
    let localhostPasswordAuthEnabled = localhostOutput.lowercased().contains("passwordauthentication yes")
    print("Localhost password auth status: \(localhostPasswordAuthEnabled ? "enabled" : "not configured")")
    
    // Check for existing Match block that might be blocking localhost
    let matchBlocksCmd = """
    grep -n '^Match' /etc/ssh/sshd_config | while read line; do
        echo "$line"
        line_num=$(echo "$line" | cut -d: -f1)
        sed -n "${line_num},/^Match\\|^$/p" /etc/ssh/sshd_config | head -5
    done
    """
    let matchBlocksResult = try await client.executeCommand(matchBlocksCmd)
    let matchBlocksOutput = String(buffer: matchBlocksResult)
    print("Existing Match blocks: \(matchBlocksOutput)")
    
    // Only add localhost password auth if it's not already enabled
    if !localhostPasswordAuthEnabled {
        print("Need to enable local password authentication while maintaining global restrictions")
        
        // Create backup of sshd_config
        let backupCmd = "echo '\(password)' | sudo -S cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.\(Int(Date().timeIntervalSince1970))"
        _ = try await client.executeCommand(backupCmd)
        
        // Check if there's already a Match block for 127.0.0.1
        let matchExistsCmd = "grep -q '^Match Address 127\\.0\\.0\\.1' /etc/ssh/sshd_config && echo 'exists' || echo 'not exists'"
        let matchExistsResult = try await client.executeCommand(matchExistsCmd)
        let matchExists = String(buffer: matchExistsResult).trimmingCharacters(in: .whitespacesAndNewlines).contains("exists")
        
        if matchExists {
            // Update existing Match block to enable password authentication
            let updateCmd = """
            echo '\(password)' | sudo -S sed -i -e '/Match Address 127\\.0\\.0\\.1/,/Match\\|$/ { /PasswordAuthentication/ { s/no/yes/ } }' /etc/ssh/sshd_config
            """
            _ = try await client.executeCommand(updateCmd)
            
            // Add PasswordAuthentication yes if it doesn't exist in the block
            let ensurePasswordCmd = """
            echo '\(password)' | sudo -S sed -i -e '/Match Address 127\\.0\\.0\\.1/a\\
            \\    PasswordAuthentication yes' /etc/ssh/sshd_config
            """
            _ = try await client.executeCommand(ensurePasswordCmd)
        } else {
            // Add new Match block
            let configLines = """
            
            # Added by Throttle for secure local tunnel access
            Match Address 127.0.0.1
                PasswordAuthentication yes
            """
            
            let appendCmd = """
            echo '\(password)' | sudo -S bash -c 'echo "\(configLines)" >> /etc/ssh/sshd_config'
            """
            _ = try await client.executeCommand(appendCmd)
        }
        
        // Verify the configuration is valid
        let testConfigCmd = "echo '\(password)' | sudo -S sshd -t"
        let testResult = try await client.executeCommand(testConfigCmd)
        let testOutput = String(buffer: testResult).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if testOutput.isEmpty {
            // Configuration is valid, restart SSH service
            let restartCmd = """
            echo '\(password)' | sudo -S systemctl restart sshd 2>/dev/null || 
            echo '\(password)' | sudo -S service ssh restart 2>/dev/null || 
            echo '\(password)' | sudo -S /etc/init.d/ssh restart 2>/dev/null
            """
            _ = try await client.executeCommand(restartCmd)
            print("Successfully configured local password authentication")
            
            // Test if it actually works now
            let finalTestCmd = """
            sshpass -p '\(password)' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \(server.sftpUser ?? "")@127.0.0.1 echo 'success' 2>&1 || echo 'failed'
            """
            let finalResult = try await client.executeCommand(finalTestCmd)
            let finalOutput = String(buffer: finalResult).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if finalOutput.contains("success") {
                print("Verified: Local password authentication now works")
            } else {
                print("Warning: Configuration applied but password auth still not working. Other factors may be blocking it.")
            }
        } else {
            // Configuration is invalid, restore backup
            let restoreCmd = "echo '\(password)' | sudo -S mv /etc/ssh/sshd_config.bak.\(Int(Date().timeIntervalSince1970)) /etc/ssh/sshd_config"
            _ = try await client.executeCommand(restoreCmd)
            print("Configuration failed validation. Restored backup. Error: \(testOutput)")
        }
    }
}
