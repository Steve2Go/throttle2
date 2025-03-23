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
                Text("Install Components")
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
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status indicator
                    HStack {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                            Text(installationComplete ? "Complete!" : "Installing...")
                                .foregroundColor(installationComplete ? .green : .primary)
                        } else {
                            Text("Ready to install")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    // Installation items
                    installationItem(
                        title: "FUSE-T",
                        description: "File system in user space",
                        status: outputContains("Successfully installed fuse-t") ? .complete :
                                outputContains("Installing fuse-t") ? .inProgress : .pending
                    )
                    
                    installationItem(
                        title: "SSHFS",
                        description: "SSH Filesystem",
                        status: outputContains("Successfully installed sshfs") ? .complete :
                                outputContains("Installing sshfs") ? .inProgress : .pending
                    )
                    
                    installationItem(
                        title: "Hosts Configuration",
                        description: "Add 127.0.0.1 Throttle entry",
                        status: outputContains("Successfully updated hosts") || 
                               outputContains("already exists in hosts") ? .complete :
                               outputContains("Checking hosts") ? .inProgress : .pending
                    )
                    
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
                                .background(Color(.systemGray6))
                                .cornerRadius(4)
                        }
                    }
                }
                .padding()
            }
            
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
    
    enum InstallStatus {
        case pending, inProgress, complete
    }
    
    func installationItem(title: String, description: String, status: InstallStatus) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Status indicator
            Group {
                switch status {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                case .inProgress:
                    ProgressView()
                        .controlSize(.small)
                case .complete:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6).opacity(0.5))
        .cornerRadius(8)
    }
    
    func outputContains(_ text: String) -> Bool {
        return installationOutput.contains(text)
    }
    
    func performInstallation() {
        isInstalling = true
        installationOutput = "Starting installation process...\n"
        
        // Run the installation steps on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Install FUSE-T package
            installPackage(named: "fuse-t-macos-installer-1.0.44.pkg")
            
            // Step 2: Install SSHFS package
            installPackage(named: "sshfs-macos-installer-1.0.2.pkg")
            
            // Step 3: Check and update hosts file
            checkAndUpdateHostsFile()
            
            // Complete the installation
            DispatchQueue.main.async {
                installationOutput += "\nInstallation completed!"
                installationComplete = true
                isInstalling = false
            }
        }
    }
    
    func installPackage(named packageName: String) {
        appendOutput("Installing \(packageName)...")
        
        guard let packageURL = Bundle.main.url(forResource: packageName.replacingOccurrences(of: ".pkg", with: ""), withExtension: "pkg") else {
            appendOutput("Error: Package \(packageName) not found in app bundle.")
            return
        }
        
        let process = Process()
        let pipe = Pipe()
        
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.launchPath = "/usr/bin/env"
        process.arguments = ["osascript", "-e", "do shell script \"installer -pkg '\(packageURL.path)' -target /\" with administrator privileges"]
        
        // Capture and display output
        captureProcessOutput(process: process, pipe: pipe)
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                appendOutput("Successfully installed \(packageName).")
            } else {
                appendOutput("Failed to install \(packageName) with error code: \(process.terminationStatus)")
            }
        } catch {
            appendOutput("Error launching installer: \(error.localizedDescription)")
        }
    }
    
    func checkAndUpdateHostsFile() {
        appendOutput("\nChecking hosts file...")
        
        // Step 1: First check if entry already exists
        let checkProcess = Process()
        let checkPipe = Pipe()
        
        checkProcess.standardOutput = checkPipe
        checkProcess.standardError = checkPipe
        
        checkProcess.launchPath = "/usr/bin/env"
        checkProcess.arguments = ["grep", "-q", "127.0.0.1 Throttle", "/etc/hosts"]
        
        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            
            if checkProcess.terminationStatus == 0 {
                // Entry exists
                appendOutput("Entry '127.0.0.1 Throttle' already exists in hosts file.")
                return
            }
            
            // Entry doesn't exist, add it
            appendOutput("Adding entry to hosts file...")
            
            let updateProcess = Process()
            let updatePipe = Pipe()
            
            updateProcess.standardOutput = updatePipe
            updateProcess.standardError = updatePipe
            
            updateProcess.launchPath = "/usr/bin/env"
            updateProcess.arguments = ["osascript", "-e", "do shell script \"echo '127.0.0.1 Throttle' >> /etc/hosts\" with administrator privileges"]
            
            captureProcessOutput(process: updateProcess, pipe: updatePipe)
            
            try updateProcess.run()
            updateProcess.waitUntilExit()
            
            if updateProcess.terminationStatus == 0 {
                appendOutput("Successfully updated hosts file.")
            } else {
                appendOutput("Failed to update hosts file with error code: \(updateProcess.terminationStatus)")
            }
        } catch {
            appendOutput("Error checking/updating hosts file: \(error.localizedDescription)")
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

// Example of how to use this in your main app
struct ContentView: View {
    @State private var showingInstaller = false
    
    var body: some View {
        Button("Show Installer") {
            showingInstaller = true
        }
        .sheet(isPresented: $showingInstaller) {
            InstallerView()
        }
    }
}