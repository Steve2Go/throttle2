#if os(macOS)
import Foundation
import KeychainAccess
import Combine
import AppKit

enum MountError: Error {
    case directoryCreationFailed
    case mountProcessFailed
    case invalidServerConfiguration
    case alreadyMounted
    case unmountFailed
}

class MountManager: ObservableObject {
    @Published var mountProcesses: [String: Process] = [:] // Server name to Process mapping
    @Published var mountStatus: [String: Bool] = [:] // Server name to mount status mapping
    @Published var mountErrors: [String: Error] = [:]
    
    private var cancellables = Set<AnyCancellable>()
    private let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    private let queue = DispatchQueue(label: "com.srgim.Throttle-2.mount", qos: .userInitiated)
    private let retryAttempts = 3
    private let retryDelay: TimeInterval = 2.0
    
    init() {
        #if os(macOS)
        // Setup cleanup on app termination
        NotificationCenter.default.addObserver(self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil)
        
        // Setup periodic health check
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkMountHealth()
            }
            .store(in: &cancellables)
        #endif
    }
    
    func getMountPath(for server: ServerEntity) -> URL {
        let tmpURL = URL(fileURLWithPath: "/tmp")
        return tmpURL.appendingPathComponent("com.srgim.Throttle-2.sftp/\(server.name ?? "unknown")", isDirectory: true)
    }
    
    private func validateServerConfiguration(_ server: ServerEntity) -> Bool {
        guard let name = server.name,
              let user = server.sftpUser,
              let host = server.sftpHost,
              let path = server.pathServer,
              !name.isEmpty,
              !user.isEmpty,
              !host.isEmpty
        else {
            return false
        }
        return true
    }
    
    private func isDirectoryMounted(_ path: URL) -> Bool {
        #if os(macOS)
        let process = Process()
        process.launchPath = "/bin/df"
        process.arguments = [path.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("sshfs")
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
    
    func mountFolder(server: ServerEntity, retry: Int = 0) {
        #if os(macOS)
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Validation
            guard validateServerConfiguration(server) else {
                self.handleError(MountError.invalidServerConfiguration, for: server)
                return
            }
            
            let directoryURL = getMountPath(for: server)
            
            // Check if already mounted
            if isDirectoryMounted(directoryURL) {
                self.handleError(MountError.alreadyMounted, for: server)
                return
            }
            
            // Create directory if needed
            do {
                try FileManager.default.createDirectory(at: directoryURL,
                                                      withIntermediateDirectories: true,
                                                      attributes: nil)
            } catch {
                self.handleError(error, for: server)
                return
            }
            
            // Setup mount process
            let process = Process()
            process.launchPath = "/bin/zsh"
            
            let sfptpass = self.keychain["sftpPassword" + (server.name ?? "")] ?? ""
            let url = directoryURL.path
            let user = server.sftpUser ?? ""
            let host = server.sftpHost ?? ""
            let filesystemPath = server.pathServer ?? ""
            
            // Enhanced SSHFS options for reliability
            let sshfsOptions = [
                "password_stdin",
                "ServerAliveInterval=30",
                "ServerAliveCountMax=4",
                "reconnect",
                "delay_connect",
                "auto_cache",
                "kernel_cache",
                "location=Throttle"
            ].joined(separator: ",")
            
            let command = "echo \(sfptpass) | /usr/local/bin/sshfs \(user)@\(host):\(filesystemPath) \(url) -o \(sshfsOptions)"
            process.arguments = ["-c", command]
            
            // Setup output handling
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = outPipe
            
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    print("Mount process output for \(server.name ?? ""): \(output)")
                }
            }
            
            // Setup termination handling
            process.terminationHandler = { [weak self] process in
                guard let self = self else { return }
                if process.terminationStatus != 0 && retry < self.retryAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay) {
                        print("Retrying mount for \(server.name ?? ""). Attempt \(retry + 1)")
                        self.mountFolder(server: server, retry: retry + 1)
                    }
                }
            }
            
            // Run the mount process
            do {
                try process.run()
                DispatchQueue.main.async {
                    self.mountProcesses[server.name ?? ""] = process
                    self.mountStatus[server.name ?? ""] = true
                    self.mountErrors.removeValue(forKey: server.name ?? "")
                }
            } catch {
                self.handleError(error, for: server)
                if retry < self.retryAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay) {
                        print("Retrying mount for \(server.name ?? ""). Attempt \(retry + 1)")
                        self.mountFolder(server: server, retry: retry + 1)
                    }
                }
            }
        }
        #endif
    }
    
    private func handleError(_ error: Error, for server: ServerEntity) {
        DispatchQueue.main.async {
            self.mountErrors[server.name ?? ""] = error
            self.mountStatus[server.name ?? ""] = false
        }
    }
    
    func unmountFolder(server: ServerEntity) {
        #if os(macOS)
        queue.async {
            let directoryURL = self.getMountPath(for: server)
            
            // First try graceful unmount
            let process = Process()
            process.launchPath = "/usr/bin/umount"
            process.arguments = [directoryURL.path]
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus != 0 {
                    // If graceful unmount fails, try force unmount
                    let forceProcess = Process()
                    forceProcess.launchPath = "/usr/bin/umount"
                    forceProcess.arguments = ["-f", directoryURL.path]
                    try forceProcess.run()
                    forceProcess.waitUntilExit()
                }
                
                DispatchQueue.main.async {
                    self.mountProcesses.removeValue(forKey: server.name ?? "")
                    self.mountStatus[server.name ?? ""] = false
                }
            } catch {
                self.handleError(error, for: server)
            }
        }
        #endif
    }
    
    func checkMountHealth() {
        #if os(macOS)
        for (serverName, _) in mountProcesses {
            let directoryURL = URL(fileURLWithPath: "/tmp").appendingPathComponent("com.srgim.Throttle-2.sftp/\(serverName)")
            
            if !isDirectoryMounted(directoryURL) {
                mountStatus[serverName] = false
            }
        }
        #endif
    }
    
    @objc private func applicationWillTerminate() {
        #if os(macOS)
        // Clean up all mounts when app terminates
        for (serverName, _) in mountProcesses {
            if let process = mountProcesses[serverName] {
                process.terminate()
            }
        }
        #endif
    }
    
    func mountFolders(servers: [ServerEntity]) {
        #if os(macOS)
        for server in servers where server.sftpBrowse {
            mountFolder(server: server)
        }
        #endif
    }
    
    func unmountFolders(servers: [ServerEntity]) {
        #if os(macOS)
        for server in servers {
            unmountFolder(server: server)
        }
        #endif
    }
    
    deinit {
        cancellables.removeAll()
        #if os(macOS)
        // Cleanup any remaining mounts
        for (serverName, process) in mountProcesses {
            process.terminate()
        }
        #endif
    }
}
#endif
