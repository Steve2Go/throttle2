//
//  FFmpegInstallerView.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 8/4/2025.
//


import SwiftUI
import KeychainAccess
import Citadel

struct FFmpegInstallerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var installationOutput: String = ""
    @State private var isInstalling: Bool = false
    @State private var installationComplete: Bool = false
    let server: ServerEntity
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
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
                                Text("Ready to check FFmpeg")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        
                        // Installation items
                        installationItem(
                            title: "FFmpeg Check",
                            description: "Check if FFmpeg is already installed",
                            status: outputContains("FFmpeg is installed") ? .complete :
                                    outputContains("Checking FFmpeg") ? .inProgress : .pending
                        )
                        
                        installationItem(
                            title: "Package Manager Check",
                            description: "Detect available package manager",
                            status: outputContains("Package manager found:") ? .complete :
                                    outputContains("Checking package managers") ? .inProgress : .pending
                        )
                        
                        installationItem(
                            title: "FFmpeg Installation",
                            description: "Install FFmpeg if needed",
                            status: outputContains("Successfully installed FFmpeg") ? .complete :
                                    outputContains("Installing FFmpeg") ? .inProgress : .pending
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
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                }
                
                // Action buttons
                if installationComplete {
                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: {
                        Task {
                            await performInstallation()
                        }
                    }) {
                        Text(isInstalling ? "Installing..." : "Check and Install")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                }
            }
            .navigationTitle("FFmpeg Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isInstalling {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
    
    enum InstallStatus {
        case pending, inProgress, complete
    }
    
    private func installationItem(title: String, description: String, status: InstallStatus) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
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
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func outputContains(_ text: String) -> Bool {
        return installationOutput.contains(text)
    }
    
    private func appendOutput(_ text: String) {
        DispatchQueue.main.async {
            self.installationOutput += text + "\n"
        }
    }
    
    private func performInstallation() async {
        isInstalling = true
        
        do {
            let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
            guard let username = server.sftpUser,
                  let password = keychain["sftpPassword" + (server.name ?? "")],
                  let hostname = server.sftpHost else {
                appendOutput("Error: Missing server credentials")
                return
            }
            
            // Connect to server
            let client = try await SSHClient.connect(
                host: hostname,
                port: Int(server.sftpPort),
                authenticationMethod: .passwordBased(username: username, password: password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            
            // Check if FFmpeg is already installed
            appendOutput("Checking FFmpeg installation...")
            let ffmpegCheck = try await client.executeCommand("which ffmpeg")
            if !String(buffer: ffmpegCheck).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendOutput("FFmpeg is installed at: \(String(buffer: ffmpegCheck))")
                installationComplete = true
                return
            }
            
            // Detect package manager and OS
            appendOutput("\nChecking package managers...")
            
            // Check for apt (Debian/Ubuntu)
            let aptCheck = try await client.executeCommand("which apt")
            if !String(buffer: aptCheck).isEmpty {
                appendOutput("Package manager found: apt (Debian/Ubuntu)")
                // Install FFmpeg using apt
                appendOutput("\nUpdating package list...")
                _ = try await client.executeCommand("sudo -S apt update")
                
                appendOutput("Installing FFmpeg...")
                let installResult = try await client.executeCommand("sudo -S apt install -y ffmpeg")
                appendOutput(String(buffer: installResult))
                
            } else {
                // Check for pacman (Arch)
                let pacmanCheck = try await client.executeCommand("which pacman")
                if !String(buffer: pacmanCheck).isEmpty {
                    appendOutput("Package manager found: pacman (Arch)")
                    // Install FFmpeg using pacman
                    appendOutput("\nInstalling FFmpeg...")
                    let installResult = try await client.executeCommand("sudo -S pacman -S --noconfirm ffmpeg")
                    appendOutput(String(buffer: installResult))
                    
                } else {
                    // Check for Homebrew (macOS)
                    let brewCheck = try await client.executeCommand("which brew")
                    if !String(buffer: brewCheck).isEmpty {
                        appendOutput("Package manager found: Homebrew (macOS)")
                        // Install FFmpeg using Homebrew
                        appendOutput("\nInstalling FFmpeg...")
                        let installResult = try await client.executeCommand("brew install ffmpeg")
                        appendOutput(String(buffer: installResult))
                        
                    } else {
                        // If on macOS but no Homebrew, try to install it
                        let uname = try await client.executeCommand("uname")
                        if String(buffer: uname).contains("Darwin") {
                            appendOutput("macOS detected, installing Homebrew...")
                            
                            // Install Homebrew
                            let installBrewCmd = """
                            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                            """
                            _ = try await client.executeCommand(installBrewCmd)
                            
                            // Install FFmpeg
                            appendOutput("\nInstalling FFmpeg...")
                            let installResult = try await client.executeCommand("brew install ffmpeg")
                            appendOutput(String(buffer: installResult))
                        } else {
                            appendOutput("Error: No supported package manager found")
                            return
                        }
                    }
                }
            }
            
            // Verify installation
            let finalCheck = try await client.executeCommand("which ffmpeg")
            if !String(buffer: finalCheck).isEmpty {
                appendOutput("\nSuccessfully installed FFmpeg!")
                installationComplete = true
            } else {
                appendOutput("\nError: FFmpeg installation could not be verified")
            }
            
        } catch {
            appendOutput("\nError: \(error.localizedDescription)")
        }
        
        isInstalling = false
    }
}

// Preview provider
struct FFmpegInstallerView_Previews: PreviewProvider {
    static var previews: some View {
        FFmpegInstallerView(server: ServerEntity())
    }
}