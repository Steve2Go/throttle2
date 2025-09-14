//
//  InstallerView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 20/3/2025.
//

#if os(macOS)
import SwiftUI

struct InstallerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var installationOutput: String = ""
    @State private var isInstalling: Bool = false
    @State private var installationComplete: Bool = false
    @State private var downloadProgress: Double = 0.0
    @State private var currentDownload: String = ""
    
    // Configure max size for the sheet
    let maxWidth: CGFloat = 500
    let maxHeight: CGFloat = 500
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Install Required Components")
                    .font(.headline)
                Spacer()
                if !isInstalling {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding([.horizontal, .top])
            
            // Info message
            Text("Throttle requires system components to be installed for full functionality. This process may prompt for your password and will install FUSE-T and SSHFS, configuring your system for Finder integration.")
            Text("We suggest using QLVideo if you want to see video previews in finder for all video types. https://github.com/Marginal/QLVideo.")
                .font(.body)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal)
            
            // Status indicator
            if isInstalling {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(installationComplete ? "Complete!" : "Installing...")
                        .foregroundColor(installationComplete ? .green : .primary)
                }
            }
            
            // Log output
            if !installationOutput.isEmpty {
                VStack(alignment: .leading) {
                    Text("Installation Log")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if isInstalling && !currentDownload.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Downloading: \(currentDownload)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView(value: downloadProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                        }
                        .padding(.bottom, 8)
                    }
                    
                    ScrollView {
                        Text(installationOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                    .padding(8)
                    .background(Color(.secondarySystemFill))
                    .cornerRadius(4)
                }
                .padding(.horizontal)
            }
            
            Spacer()
            
            // Action buttons
            HStack {
                Spacer()
                if installationComplete {
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: {
                        performInstallation()
                    }) {
                        Text("Install")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: maxWidth, height: maxHeight)
    }
    
    func performInstallation() {
        isInstalling = true
        installationOutput = "Starting installation process...\n"
        
        // Download all components first
        downloadAllComponents()
    }
    
    func downloadAllComponents() {
        let tempDir = NSTemporaryDirectory()
        
        // First, let's get the actual asset names from the latest releases
        fetchLatestAssetNames { assetNames in
            let downloads = [
                ("FUSE-T", "https://github.com/macos-fuse-t/fuse-t/releases/latest/download/\(assetNames.fuseT)", "fuse-t.pkg"),
                ("SSHFS", "https://github.com/macos-fuse-t/sshfs/releases/latest/download/\(assetNames.sshfs)", "sshfs.pkg")
            ]
            
            var downloadedFiles: [String] = []
            var completedDownloads = 0
            var failedDownloads = 0
            let totalDownloads = downloads.count
            
            func checkIfAllDownloadsFinished() {
                if completedDownloads + failedDownloads == totalDownloads {
                    if failedDownloads > 0 {
                        self.appendOutput("⚠️ Some downloads failed. Installation may not work properly.")
                    }
                    if completedDownloads > 0 {
                        self.currentDownload = "Downloads complete - starting installation"
                        self.runInstallationScript(downloadedFiles: downloadedFiles)
                    } else {
                        self.appendOutput("❌ All downloads failed. Cannot proceed with installation.")
                        self.isInstalling = false
                    }
                }
            }
            
            for (index, (name, urlString, localFilename)) in downloads.enumerated() {
                guard let url = URL(string: urlString) else {
                    self.appendOutput("❌ Error: Invalid URL for \(name): \(urlString)")
                    failedDownloads += 1
                    checkIfAllDownloadsFinished()
                    continue
                }
                
                let destinationPath = tempDir + localFilename
                self.appendOutput("[\(index + 1)/\(totalDownloads)] Downloading \(name)...")
                self.currentDownload = name
                
                let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.appendOutput("❌ Error downloading \(name): \(error.localizedDescription)")
                            failedDownloads += 1
                            checkIfAllDownloadsFinished()
                        }
                        return
                    }
                    
                    guard let localURL = localURL else {
                        DispatchQueue.main.async {
                            self.appendOutput("❌ Error: No file received for \(name)")
                            failedDownloads += 1
                            checkIfAllDownloadsFinished()
                        }
                        return
                    }
                    
                    do {
                        // Remove existing file if it exists
                        if FileManager.default.fileExists(atPath: destinationPath) {
                            try FileManager.default.removeItem(atPath: destinationPath)
                        }
                        
                        // Move downloaded file to destination
                        try FileManager.default.moveItem(at: localURL, to: URL(fileURLWithPath: destinationPath))
                        
                        // Check if the downloaded file is actually a directory (auto-unzipped .app)
                        var isDirectory: ObjCBool = false
                        let isFile = FileManager.default.fileExists(atPath: destinationPath, isDirectory: &isDirectory)
                        
                        downloadedFiles.append(destinationPath)
                        
                        // Verify file/directory exists and get size
                        let finalPath = downloadedFiles.last!
                        let fileSize = try FileManager.default.attributesOfItem(atPath: finalPath)[.size] as? NSNumber
                        let fileSizeBytes = fileSize?.int64Value ?? 0
                        
                        // Get the actual filename from the response
                        let actualFilename = response?.suggestedFilename ?? localFilename
                        
                        DispatchQueue.main.async {
                            let finalPath = downloadedFiles.last!
                            let fileName = URL(fileURLWithPath: finalPath).lastPathComponent
                            self.appendOutput("✓ \(name) downloaded successfully (\(self.formatFileSize(fileSizeBytes)))")
                            self.appendOutput("  Saved as: \(fileName)")
                            completedDownloads += 1
                            self.downloadProgress = Double(completedDownloads) / Double(totalDownloads)
                            
                            checkIfAllDownloadsFinished()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.appendOutput("❌ Error saving \(name): \(error.localizedDescription)")
                            failedDownloads += 1
                            checkIfAllDownloadsFinished()
                        }
                    }
                }
                
                task.resume()
            }
        }
    }
    
    struct AssetNames {
        let fuseT: String
        let sshfs: String
    }
    
    func fetchLatestAssetNames(completion: @escaping (AssetNames) -> Void) {
        let group = DispatchGroup()
        var fuseT = ""
        var sshfs = ""
        
        // Fetch FUSE-T asset name
        group.enter()
        fetchAssetName(from: "https://api.github.com/repos/macos-fuse-t/fuse-t/releases/latest", containing: "fuse-t", suffix: ".pkg") { name in
            fuseT = name ?? ""
            group.leave()
        }
        
        // Fetch SSHFS asset name
        group.enter()
        fetchAssetName(from: "https://api.github.com/repos/macos-fuse-t/sshfs/releases/latest", containing: "sshfs", suffix: ".pkg") { name in
            sshfs = name ?? ""
            group.leave()
        }
        
        group.notify(queue: .main) {
            completion(AssetNames(fuseT: fuseT, sshfs: sshfs))
        }
    }
    
    func fetchAssetName(from apiURL: String, containing: String, suffix: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: apiURL) else {
            completion(nil)
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let assets = json["assets"] as? [[String: Any]] {
                    
                    for asset in assets {
                        if let assetName = asset["name"] as? String,
                           assetName.contains(containing) && assetName.hasSuffix(suffix) {
                            completion(assetName)
                            return
                        }
                    }
                }
                completion(nil)
            } catch {
                completion(nil)
            }
        }
        
        task.resume()
    }
    
    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func runInstallationScript(downloadedFiles: [String]) {
        appendOutput("All downloads completed. Starting installation...")
        
        // Find the downloaded files and verify they exist
        let fuseTPkg = downloadedFiles.first { $0.contains("fuse-t") } ?? ""
        let sshfsPkg = downloadedFiles.first { $0.contains("sshfs") } ?? ""
        
        // Verify files exist before proceeding
        var validFiles: [String] = []
        for file in [fuseTPkg, sshfsPkg] {
            if !file.isEmpty && FileManager.default.fileExists(atPath: file) {
                validFiles.append(file)
                let fileName = URL(fileURLWithPath: file).lastPathComponent
                appendOutput("✓ Verified file: \(fileName)")
            } else if !file.isEmpty {
                appendOutput("⚠️ Warning: File not found: \(file)")
            }
        }
        
        if validFiles.isEmpty {
            appendOutput("❌ No valid installation files found. Cannot proceed.")
            isInstalling = false
            return
        }
        
        // Generate installation script
        let script = """
        #!/bin/sh
        
        echo 'Starting installation with admin privileges...'
        
        # Install FUSE-T if available
        if [ -f "\(fuseTPkg)" ]; then
          echo 'Installing FUSE-T...'
          if installer -pkg "\(fuseTPkg)" -target /; then
            echo 'FUSE-T installation completed successfully'
          else
            echo 'FUSE-T installation failed'
          fi
        else
          echo 'FUSE-T package not available - skipping'
        fi
        
        # Install SSHFS if available
        if [ -f "\(sshfsPkg)" ]; then
          echo 'Installing SSHFS...'
          if installer -pkg "\(sshfsPkg)" -target /; then
            echo 'SSHFS installation completed successfully'
          else
            echo 'SSHFS installation failed'
          fi
        else
          echo 'SSHFS package not available - skipping'
        fi
        
        # Check and update hosts file
        echo 'Checking /etc/hosts...'
        if ! grep -q "127.0.0.1 Throttle" /etc/hosts; then
          echo 'Adding Throttle to /etc/hosts...'
          echo '127.0.0.1 Throttle' >> /etc/hosts
          echo 'Throttle added to /etc/hosts'
        else
          echo 'Throttle already exists in /etc/hosts'
        fi
        
        echo 'Cleaning up downloaded files...'
        rm -f "\(fuseTPkg)" "\(sshfsPkg)"
        echo 'Installation process completed!'
        """
        
        let scriptPath = NSTemporaryDirectory() + "throttle_install.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            // Make script executable
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            appendOutput("Error writing install script: \(error.localizedDescription)")
            isInstalling = false
            return
        }

        // Run the script with a single privileged prompt
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.launchPath = "/usr/bin/env"
        process.arguments = ["osascript", "-e", "do shell script \"/bin/sh \(scriptPath)\" with administrator privileges"]

        captureProcessOutput(process: process, pipe: pipe)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
                DispatchQueue.main.async {
                    self.installationOutput += "\nInstallation completed!"
                    self.installationComplete = true
                    self.isInstalling = false
                    
                    // Clean up the script
                    try? FileManager.default.removeItem(atPath: scriptPath)
                }
            } catch {
                self.appendOutput("Error running installer: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isInstalling = false
                }
            }
        }
    }
    
    func captureProcessOutput(process: Process, pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                appendOutput(output)
            }
        }
        
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }
    
    func appendOutput(_ text: String) {
        DispatchQueue.main.async {
            self.installationOutput += text + "\n"
        }
    }
}

#endif
