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
            Text("Throttle requires system components to be installed for full functionality. This process may prompt for your password and will install FUSE-T, SSHFS, and configure your system for Finder integration.")
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
                    Text(installationOutput)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

        // 1. Get package paths
        guard let fuseTPkgURL = Bundle.main.url(forResource: "fuse-t-macos-installer-1.0.44", withExtension: "pkg"),
              let sshfsPkgURL = Bundle.main.url(forResource: "sshfs-macos-installer-1.0.2", withExtension: "pkg") else {
            appendOutput("Error: One or more installer packages not found in app bundle.")
            isInstalling = false
            return
        }
        let fuseTPkgPath = fuseTPkgURL.path
        let sshfsPkgPath = sshfsPkgURL.path

        // 2. Generate the shell script
        let script = """
        #!/bin/sh
        echo 'Installing fuse-t...'
        installer -pkg \"\(fuseTPkgPath)\" -target /
        echo 'Installing sshfs...'
        installer -pkg \"\(sshfsPkgPath)\" -target /
        if ! grep -q "127.0.0.1 Throttle" /etc/hosts; then
          echo 'Adding Throttle to /etc/hosts...'
          echo '127.0.0.1 Throttle' >> /etc/hosts
        else
          echo 'Throttle already exists in /etc/hosts.'
        fi
        """
        let scriptPath = "/tmp/throttle_install.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            // Make script executable
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            appendOutput("Error writing install script: \(error.localizedDescription)")
            isInstalling = false
            return
        }

        // 3. Run the script with a single privileged prompt
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
                // 4. Launch QuickLookVideo (no sudo needed)
                installQuickLookVideo()
                DispatchQueue.main.async {
                    installationOutput += "\nInstallation completed!"
                    installationComplete = true
                    isInstalling = false
                }
            } catch {
                appendOutput("Error running installer: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    isInstalling = false
                }
            }
        }
    }
    
    func installQuickLookVideo() {
        appendOutput("\nInstalling QuickLookVideo...")
        
        guard let appURL = Bundle.main.url(forResource: "QuickLookVideo", withExtension: "app") else {
            appendOutput("Error: QuickLookVideo.app not found in app bundle.")
            return
        }
        
        // Open the app using NSWorkspace
        DispatchQueue.main.async {
            do {
                try NSWorkspace.shared.open(appURL)
                self.appendOutput("\nSuccessfully launched QuickLookVideo.")
            } catch {
                self.appendOutput("\nError launching QuickLookVideo: \(error.localizedDescription)")
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
