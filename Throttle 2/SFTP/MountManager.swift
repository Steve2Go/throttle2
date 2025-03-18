import Foundation
import KeychainAccess
import CoreData

class MountManager: ObservableObject {
    @Published var mountProcesses: [Process] = []
    let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
    
    func mountFolder(server: ServerEntity) {
        #if os(macOS)
        if server.sftpBrowse {
            let sfptpass = keychain["sftpPassword" + (server.name ?? "")] ?? ""
            
            let fileManager = FileManager.default
            let tmpURL = URL(fileURLWithPath: "/tmp")
            let directoryURL = tmpURL.appendingPathComponent("com.srgim.Throttle-2.sftp/\(server.name!)", isDirectory: true)
            
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
                print("Directory created at \(directoryURL)")
            } catch {
                print("Creation failed: \(error)")
            }
            
            let process = Process()
            process.launchPath = "/bin/zsh"
            
            let url = directoryURL.absoluteString.replacingOccurrences(of: "file://", with: "")
            let user = server.sftpUser ?? ""
            let host = server.sftpHost ?? ""
            let filesystemPath = server.pathServer ?? ""
            let command = "echo \(sfptpass) | /usr/local/bin/sshfs \(user)@\(host):\(filesystemPath) \(url) -o password_stdin -o ServerAliveInterval=30"
            process.arguments = ["-c", command]
            
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = outPipe
            
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    print("Process output: \(output)")
                }
            }
            
            do {
                try process.run()
                print("Process started successfully.")
                mountProcesses.append(process)
            } catch {
                print("Error running process: \(error)")
            }
        }
        #endif
    }
    
    func mountFolders(servers: FetchedResults<ServerEntity>) {
        #if os(macOS)
        for server in servers {
            mountFolder(server: server)
        }
        #endif
    }
    
    func unmountFolder(server: ServerEntity) {
        #if os(macOS)
        let fileManager = FileManager.default
        let tmpURL = URL(fileURLWithPath: "/tmp")
        let directoryURL = tmpURL.appendingPathComponent("com.srgim.Throttle-2.sftp/\(server.name!)", isDirectory: true)
        
        let UMprocess = Process()
        UMprocess.launchPath = "/usr/local/bin/sshfs"
        UMprocess.arguments = ["umount \(directoryURL)"]
        UMprocess.launch()
        #endif
    }
    
    func unmountFolders(servers: FetchedResults<ServerEntity>) {
        #if os(macOS)
        for server in servers {
            unmountFolder(server: server)
        }
        #endif
    }
}