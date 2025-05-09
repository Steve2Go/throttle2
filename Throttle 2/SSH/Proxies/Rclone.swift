//import Foundation
//import CoreData
//import KeychainAccess
//import AppKit
//
//class RcloneManager {
//    static let shared = RcloneManager()
//    private let userDefaultsKey = "rclonePath"
//    private var rcloneDownloadURL: String {
//        #if arch(arm64)
//        return "https://downloads.rclone.org/rclone-current-osx-arm64.zip"
//        #else
//        return "https://downloads.rclone.org/rclone-current-osx-amd64.zip"
//        #endif
//    }
//    private let rcloneExecutableName = "rclone"
//    private let appSupportDir: URL = {
//        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
//        let dir = paths[0].appendingPathComponent("Throttle2/bin", isDirectory: true)
//        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
//        return dir
//    }()
//    private let configFileName = "rclone.conf"
//    private let keyDirName = "rclone-keys"
//
//    private let commonPaths = [
//        "/usr/local/bin/rclone",
//        "/opt/homebrew/bin/rclone",
//        "/usr/bin/rclone"
//    ]
//
//    /// Ensures rclone is available. If not, downloads and installs it. Calls completion with the path.
//    func ensureRcloneAvailable(completion: @escaping (String?) -> Void) {
//        // 1. Check UserDefaults
//        if let savedPath = UserDefaults.standard.string(forKey: userDefaultsKey), FileManager.default.isExecutableFile(atPath: savedPath) {
//            completion(savedPath)
//            return
//        }
//        // 2. Check common locations
//        for path in commonPaths {
//            if FileManager.default.isExecutableFile(atPath: path) {
//                UserDefaults.standard.set(path, forKey: userDefaultsKey)
//                completion(path)
//                return
//            }
//        }
//        // 3. Check app support dir
//        let appSupportPath = appSupportDir.appendingPathComponent(rcloneExecutableName).path
//        if FileManager.default.isExecutableFile(atPath: appSupportPath) {
//            UserDefaults.standard.set(appSupportPath, forKey: userDefaultsKey)
//            completion(appSupportPath)
//            return
//        }
//        // 4. Download and install
//        downloadAndInstallRclone { [weak self] installedPath in
//            if let installedPath = installedPath {
//                UserDefaults.standard.set(installedPath, forKey: self?.userDefaultsKey ?? "rclonePath")
//            }
//            completion(installedPath)
//        }
//    }
//
//    private func downloadAndInstallRclone(completion: @escaping (String?) -> Void) {
//        let url = URL(string: rcloneDownloadURL)!
//        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
//            guard let tempURL = tempURL, error == nil else {
//                print("Failed to download rclone: \(error?.localizedDescription ?? "unknown error")")
//                completion(nil)
//                return
//            }
//            // Unzip and move to appSupportDir
//            let fileManager = FileManager.default
//            let unzipDir = self.appSupportDir.appendingPathComponent("rclone-unzip-")
//            do {
//                try fileManager.createDirectory(at: unzipDir, withIntermediateDirectories: true)
//                let process = Process()
//                process.launchPath = "/usr/bin/unzip"
//                process.arguments = [tempURL.path, "-d", unzipDir.path]
//                process.launch()
//                process.waitUntilExit()
//                // Find rclone binary in unzipped folder
//                let contents = try fileManager.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)
//                if let rcloneBin = contents.first(where: { $0.lastPathComponent == self.rcloneExecutableName || $0.lastPathComponent.hasPrefix("rclone") }) {
//                    let dest = self.appSupportDir.appendingPathComponent(self.rcloneExecutableName)
//                    try? fileManager.removeItem(at: dest)
//                    try fileManager.copyItem(at: rcloneBin, to: dest)
//                    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
//                    completion(dest.path)
//                    return
//                }
//            } catch {
//                print("Failed to install rclone: \(error)")
//            }
//            completion(nil)
//        }
//        task.resume()
//    }
//
//    /// Regenerate the rclone config file from all SFTP servers in Core Data, writing key files as needed.
//    /// Dismounts any existing rclone mounts for servers that have changed.
//    func regenerateRcloneConfig(context: NSManagedObjectContext) {
//        let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
//        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)]
//        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
//        let configURL = appSupportDir.appendingPathComponent(configFileName)
//        let keyDir = appSupportDir.appendingPathComponent(keyDirName, isDirectory: true)
//        try? FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
//        var config = ""
//        do {
//            let servers = try context.fetch(fetchRequest)
//            for server in servers where server.sftpHost != nil && server.sftpUser != nil && server.sftpBrowse {
//                let remoteName = server.sftpHost ?? "sftp"
//                let host = server.sftpHost ?? ""
//                let port = server.sftpPort != 0 ? String(server.sftpPort) : "22"
//                let user = server.sftpUser ?? ""
//                let path = server.pathServer ?? "/"
//                let useKey = server.sftpUsesKey
//                let password = keychain["sftpPassword" + (server.name ?? "")] ?? ""
//                let passphrase = keychain["sftpPhrase" + (server.name ?? "")] ?? ""
//                var keyFilePath: String? = nil
//                if useKey, let keyContent = keychain["sftpKey" + (server.name ?? "")] {
//                    let keyFile = keyDir.appendingPathComponent(remoteName + ".key")
//                    try? keyContent.write(to: keyFile, atomically: true, encoding: .utf8)
//                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
//                    keyFilePath = keyFile.path
//                }
//                // Dismount any existing rclone mount for this remote (if needed)
//               
//                // Write config section
//                config += "[\(remoteName)]\n"
//                config += "type = sftp\n"
//                config += "host = \(host)\n"
//                config += "user = \(user)\n"
//                config += "port = \(port)\n"
//                if !useKey {
//                    config += "pass = \(password.isEmpty ? "" : rcloneObscure(password))\n"
//                }
//                if let keyFilePath = keyFilePath {
//                    config += "key_file = \(keyFilePath)\n"
//                }
//                if !passphrase.isEmpty {
//                    config += "key_pass = \(rcloneObscure(passphrase))\n"
//                }
//                config += "\n"
//            }
//            try config.write(to: configURL, atomically: true, encoding: .utf8)
//        } catch {
//            print("Failed to regenerate rclone config: \(error)")
//        }
//    }
//
//    /// Unmounts an rclone remote by remote name and mount path
//    func unmountRcloneRemote(remoteName: String, mountPath: String, completion: @escaping (Bool) -> Void) {
//        ensureRcloneAvailable { rclonePath in
//            guard let rclonePath = rclonePath else {
//                completion(false)
//                return
//            }
//            let process = Process()
//            process.launchPath = rclonePath
//            process.arguments = ["unmount", mountPath]
//            let pipe = Pipe()
//            process.standardOutput = pipe
//            process.standardError = pipe
//            process.terminationHandler = { proc in
//                let success = proc.terminationStatus == 0
//                completion(success)
//            }
//            do {
//                try process.run()
//            } catch {
//                print("Failed to run rclone unmount: \(error)")
//                completion(false)
//            }
//        }
//    }
//
//     /// Obscure a password for rclone config
//    private func rcloneObscure(_ value: String) -> String {
//        // Call rclone obscure or use a simple placeholder (for demo)
//        // In production, you should call 'rclone obscure' and capture the output
//        return value // TODO: Actually obscure using rclone
//    }
//
//
//    /// Returns the mount path for a given server (macOS only), using '__' as separator for user and host
//    func mountPath(for server: ServerEntity) -> URL {
//        let user = server.sftpUser ?? "user"
//        let host = server.sftpHost ?? "host"
//        let folderName = "\(user)__\(host)"
//        let throttleRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Throttle", isDirectory: true)
//        try? FileManager.default.createDirectory(at: throttleRoot, withIntermediateDirectories: true)
//        return throttleRoot.appendingPathComponent(folderName, isDirectory: true)
//    }
//
//    /// Removes the mount folder for a given server (if empty)
//    func removeMountFolder(for server: ServerEntity) {
//        let mountURL = mountPath(for: server)
//        do {
//            let contents = try FileManager.default.contentsOfDirectory(atPath: mountURL.path)
//            if contents.isEmpty {
//                try FileManager.default.removeItem(at: mountURL)
//            }
//        } catch {
//            // Ignore errors (folder may not exist or not be empty)
//        }
//    }
//
//    /// Serves a remote as NFS using rclone serve nfs, creates a mount folder in /tmp/Throttle/<host>/, mounts it, and returns the mount path.
//    func serveNFS(for server: ServerEntity, port: Int? = nil, completion: @escaping (String?) -> Void) {
//        ensureRcloneAvailable { rclonePath in
//            guard let rclonePath = rclonePath else {
//                completion(nil)
//                return
//            }
//            let remoteName = server.sftpHost ?? "sftp"
//            let host = server.sftpHost ?? "host"
//            let configPath = self.appSupportDir.appendingPathComponent(self.configFileName).path
//            let pathServer = server.pathServer ?? "/"
//            // Use a unique port per server (or provided)
//            let basePort = 2049
//            let portNum = port ?? (basePort + abs(remoteName.hashValue % 1000))
//            let mountPath = "/tmp/Throttle/\(host)/"
//            // 1. Create the mount directory
//            do {
//                try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true, attributes: nil)
//            } catch {
//                print("Failed to create mount directory: \(error)")
//                completion(nil)
//                return
//            }
//            // 2. Start rclone serve nfs
//            UserDefaults.standard.set(mountPath, forKey: "mountPath")
//            let process = Process()
//            process.launchPath = rclonePath
//            process.arguments = [
//                "serve", "nfs",
//                "\(remoteName):\(pathServer)",
//                "--config", configPath,
//                "--addr", "127.0.0.1:\(portNum)",
//                "--vfs-cache-mode=full",
//                "--vfs-cache-max-size", "10G",
//                "--vfs-read-chunk-size", "256M",
//                "--buffer-size", "128M",
//                "--nfs-cache-type", "disk",
//                "--nfs-cache-dir", "/tmp/Throttle/nfs-cache/\(host)"
//            ]
//            process.standardOutput = nil
//            process.standardError = nil
//            do {
//                try process.run()
//            } catch {
//                print("Failed to start rclone serve nfs: \(error)")
//                completion(nil)
//                return
//            }
//            // 3. Mount the NFS share (no sudo)
//            let mountCmd = [
//                "/sbin/mount_nfs", // macOS-specific, use "/bin/mount" with -t nfs on Linux
//                "-o", "port=\(portNum),mountport=\(portNum),tcp,nolock,vers=3",
//                "127.0.0.1:/", mountPath
//            ]
//            let mountProcess = Process()
//            mountProcess.launchPath = mountCmd[0]
//            mountProcess.arguments = Array(mountCmd.dropFirst())
//            mountProcess.standardOutput = nil
//            mountProcess.standardError = nil
//            do {
//                try mountProcess.run()
//                mountProcess.waitUntilExit()
//                if mountProcess.terminationStatus == 0 {
//                    completion(mountPath)
//                } else {
//                    print("Failed to mount NFS share, status: \(mountProcess.terminationStatus)")
//                    completion(nil)
//                }
//            } catch {
//                print("Failed to run mount command: \(error)")
//                completion(nil)
//            }
//        }
//    }
//
//    /// Unmounts the NFS share for a server and removes the mount directory.
//    func unmountNFS(for server: ServerEntity, completion: @escaping (Bool) -> Void) {
//        let host = server.sftpHost ?? "host"
//        let mountPath = "/tmp/Throttle/\(host)/"
//        // 1. Unmount the NFS share
//        let umountProcess = Process()
//        umountProcess.launchPath = "/sbin/umount" // macOS-specific; use /bin/umount on Linux
//        umountProcess.arguments = [mountPath]
//        umountProcess.standardOutput = nil
//        umountProcess.standardError = nil
//        do {
//            try umountProcess.run()
//            umountProcess.waitUntilExit()
//            if umountProcess.terminationStatus == 0 {
//                // 2. Remove the mount directory
//                do {
//                    try FileManager.default.removeItem(atPath: mountPath)
//                } catch {
//                    // Directory may not exist or may not be empty; ignore
//                }
//                completion(true)
//            } else {
//                print("Failed to unmount NFS share, status: \(umountProcess.terminationStatus)")
//                completion(false)
//            }
//        } catch {
//            print("Failed to run umount command: \(error)")
//            completion(false)
//        }
//    }
//
//    /// Unmounts all NFS shares for SFTP-enabled servers in Core Data.
//    func unmountAllNFS(context: NSManagedObjectContext, completion: ((Int) -> Void)? = nil) {
//        let fetchRequest: NSFetchRequest<ServerEntity> = ServerEntity.fetchRequest()
//        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ServerEntity.name, ascending: true)]
//        do {
//            let servers = try context.fetch(fetchRequest)
//            let sftpServers = servers.filter { $0.sftpHost != nil && $0.sftpUser != nil && $0.sftpBrowse }
//            var unmountedCount = 0
//            let group = DispatchGroup()
//            for server in sftpServers {
//                group.enter()
//                self.unmountNFS(for: server) { success in
//                    if success { unmountedCount += 1 }
//                    group.leave()
//                }
//            }
//            group.notify(queue: .main) {
//                completion?(unmountedCount)
//            }
//        } catch {
//            print("Failed to fetch servers for NFS unmounting: \(error)")
//            completion?(0)
//        }
//    }
//} 
