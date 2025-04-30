#if os(iOS)
import SwiftUI
import KeychainAccess
import Citadel
import SimpleToast

struct DependencyInstallerView: View {
    @Environment(\.dismiss) private var dismiss
    // Use @StateObject instead of @State for the SSH connection to ensure it persists
    @StateObject private var installationState = InstallationState()
    @State var showToast = false
    @State private var sudoPassword: String = ""
    @State private var showSudoField: Bool = false
    let server: ServerEntity
    
    private let toastOptions = SimpleToastOptions(
        hideAfter: 5
    )
    
    // Create a class to hold the installation state
    class InstallationState: ObservableObject {
        @Published var installationOutput: String = ""
        @Published var isInstalling: Bool = false
        @Published var installationComplete: Bool = false
        @Published var client: SSHClient?
        @Published var sudoPassword: String = ""
        
        func appendOutput(_ text: String) {
            DispatchQueue.main.async {
                self.installationOutput += text + "\n"
            }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Status indicator
                        HStack {
                            if installationState.isInstalling {
                                ProgressView()
                                    .controlSize(.small)
                                Text(installationState.installationComplete ? "Complete!" : "Installing...")
                                    .foregroundColor(installationState.installationComplete ? .green : .primary)
                            } else {
                                Text("Ready to install FFmpeg")
                                    .foregroundColor(.secondary)
                                Text("This script will look for FFMpeg on your server, and if not found, attempt to install it for you.").font(.caption)
                            }
                            Spacer()
                        }
                        
                        // Sudo password field (only shown for key-based authentication)
                        if server.sftpUsesKey && !installationState.isInstalling {
                            VStack(alignment: .leading) {
                                Text("Sudo Password")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                SecureField("Enter sudo password (if required)", text: $sudoPassword)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                
                                Text("This password will be used for sudo operations")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Log output
                        if !installationState.installationOutput.isEmpty {
                            VStack(alignment: .leading) {
                                Text("Installation Log")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if installationState.installationOutput.contains("[Copy Windows Install Command]") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(installationState.installationOutput.replacingOccurrences(of: "[Copy Windows Install Command]", with: ""))
                                            .font(.system(.caption, design: .monospaced))
                                        
                                        Button(action: {
                                            UIPasteboard.general.string = "powershell -Command \"Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/BtbN/FFmpeg-Builds/master/ffmpeg-n6.0-latest-win64-gpl-shared.zip' -OutFile '$env:TEMP\\ffmpeg.zip'; Expand-Archive -Path '$env:TEMP\\ffmpeg.zip' -DestinationPath '$env:TEMP\\ffmpeg' -Force; $ffmpegDir = (Get-ChildItem -Path '$env:TEMP\\ffmpeg' -Directory).FullName; New-Item -Path 'C:\\FFmpeg\\bin' -ItemType Directory -Force; Copy-Item -Path \"$ffmpegDir\\bin\\*\" -Destination 'C:\\FFmpeg\\bin' -Force -Recurse; $path = [Environment]::GetEnvironmentVariable('Path', 'Machine'); if (-not $path.Contains('C:\\FFmpeg\\bin')) { [Environment]::SetEnvironmentVariable('Path', $path + ';C:\\FFmpeg\\bin', 'Machine'); }\""
                                            showToast.toggle()
                                        }) {
                                            HStack {
                                                Image(systemName: "doc.on.doc")
                                                Text("Copy Windows Install Command")
                                            }
                                            .padding(8)
                                            .background(Color.blue)
                                            .foregroundColor(.white)
                                            .cornerRadius(8)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(8)
                                } else {
                                    Text(installationState.installationOutput)
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .padding()
                    .simpleToast(isPresented: $showToast, options: toastOptions) {
                        Label("Text Copied", systemImage: "document.on.document")
                        .padding()
                        .background(Color.green.opacity(0.8))
                        .foregroundColor(Color.white)
                        .cornerRadius(10)
                        .padding(.top)
                    }
                }
                
                // Action buttons
                if installationState.installationComplete {
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
                        Text(installationState.isInstalling ? "Installing..." : "Install Dependencies")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installationState.isInstalling)
                }
            }
            .navigationTitle("Install Dependencies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !installationState.isInstalling {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
            // Clean up SSH connection when view disappears
            .onDisappear {
                Task {
                    if let client = installationState.client {
                        try? await client.close()
                        installationState.client = nil
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
        return installationState.installationOutput.contains(text)
    }
    
    private func appendOutput(_ text: String) {
        DispatchQueue.main.async {
            self.installationState.installationOutput += text + "\n"
        }
    }
    
    private func performInstallation() async {
        // Set isInstalling to true immediately to prevent double-clicks
        await MainActor.run {
            installationState.isInstalling = true
            // Store sudo password in state if using key authentication
            if server.sftpUsesKey {
                installationState.sudoPassword = sudoPassword
            }
        }
        
        do {
            let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2").synchronizable(true)
   
            // Get SSH password if not using key authentication
            let password: String
            if server.sftpUsesKey {
                // Using key authentication, use provided sudo password
                password = sudoPassword
            } else {
                // Using password authentication, get password from keychain
                guard let storedPassword = keychain["sftpPassword" + (server.name ?? "")] else {
                    installationState.appendOutput("Error: Missing server Password")
                    return
                }
                password = storedPassword
            }
            
            // Connect to server
            installationState.appendOutput("Connecting to server \(server.sftpHost!)...")
            let client = try await ServerManager.shared.connectSSH(server)
            // Store client in state to properly clean up later
            await MainActor.run {
                installationState.client = client
            }
            
            installationState.appendOutput("Connected successfully!")
            
            // Create the installation script on the remote server
            installationState.appendOutput("Preparing installation script...")
            
            // First, check if it's Linux/Unix by trying uname (should work on all Unix-like systems)
            let unameCmd = "uname -s 2>/dev/null || echo \"Unknown\""
            let unameResult = try await client.executeCommand(unameCmd)
            let osType = String(buffer: unameResult).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // If uname works, we're on a Unix-like system (Linux, macOS, FreeBSD, etc.)
            if osType != "Unknown" && !osType.isEmpty && !osType.contains("not found") {
                installationState.appendOutput("Detected Unix-like Operating System: \(osType)")
                
                // This is the content of our FFmpeg installer script for non-Windows systems
                let scriptContent = """
                #!/bin/bash
                # Cross-Platform FFmpeg Static Build Installer
                # This script detects the platform and installs the appropriate FFmpeg static build

                set -e

                echo "************************************************"
                echo "************************************************"
                echo "**** FFMPEG STATIC INSTALLER"
                echo "**** This script installs the latest static FFmpeg build appropriate for your platform"
                echo "************************************************"
                echo "************************************************"

                # Check if FFmpeg is already installed
                if command -v ffmpeg &>/dev/null && command -v ffprobe &>/dev/null; then
                    FFMPEG_PATH=$(which ffmpeg)
                    FFPROBE_PATH=$(which ffprobe)
                    echo "FFmpeg is already installed:"
                    echo "  ffmpeg: $FFMPEG_PATH ($(ffmpeg -version | head -n1))"
                    echo "  ffprobe: $FFPROBE_PATH ($(ffprobe -version | head -n1))"
                    
                    # Check if --force flag is provided
                    if [[ "$1" == "--force" ]]; then
                        echo "Force flag detected. Proceeding with reinstallation..."
                    else
                        echo "Use --force to reinstall anyway."
                        exit 0
                    fi
                fi

                # Detect the operating system
                OS="$(uname -s)"
                ARCH="$(uname -m)"

                echo "Detected operating system: $OS"
                echo "Detected architecture: $ARCH"

                # Create a temporary directory
                TEMP_DIR=$(mktemp -d)
                echo "Using temporary directory: $TEMP_DIR"

                # Store the current directory
                CURRENT_DIR=$(pwd)

                # Check if sudo is available and required
                if hash sudo 2>/dev/null; then
                    echo "sudo is available. Will use it for system-wide installation."
                    SUDO="sudo"
                    
                    # Check if sudo requires password
                    if ! sudo -n true 2>/dev/null; then
                        echo "Sudo requires password. Will use sudo -S for piping password."
                        USE_SUDO_S=1
                    else
                        echo "Sudo does not require password for this user."
                        USE_SUDO_S=0
                    fi
                else
                    echo "sudo is not available. Will attempt installation without it."
                    SUDO=""
                    USE_SUDO_S=0
                fi

                # Function to check if a command exists
                command_exists() {
                    command -v "$1" >/dev/null 2>&1
                }

                # Function to download a file
                download_file() {
                    local url="$1"
                    local output="$2"
                    
                    echo "Downloading $url to $output"
                    
                    if command_exists curl; then
                        curl -L -o "$output" "$url"
                    elif command_exists wget; then
                        wget -O "$output" "$url"
                    else
                        echo "Error: Neither curl nor wget is available. Please install one of them."
                        exit 1
                    fi
                }

                # Cleanup on exit
                cleanup() {
                    echo "Cleaning up temporary directory..."
                    rm -rf "$TEMP_DIR"
                    cd "$CURRENT_DIR"
                }
                trap cleanup EXIT

                # Function to run sudo command with password if needed
                run_sudo() {
                    if [ "$USE_SUDO_S" -eq 1 ]; then
                        # Use sudo -S to read password from stdin
                        # We don't echo the password here as it would show in logs
                        # It will be piped in from the caller
                        sudo -S "$@"
                    else
                        # Normal sudo without password
                        sudo "$@"
                    fi
                }

                # Function to install FFmpeg on macOS
                install_macos() {
                    echo "Installing FFmpeg for macOS ($ARCH)..."
                    
                    if [ "$ARCH" = "arm64" ]; then
                        # M1/M2 Mac
                        FFMPEG_URL="https://www.osxexperts.net/ffmpeg6arm.zip"
                        FFPROBE_URL="https://www.osxexperts.net/ffprobe6arm.zip"
                    else
                        # Intel Mac
                        # Get the URL from evermeet.cx
                        if command_exists jq; then
                            FFMPEG_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffmpeg/6.0' -fsS | jq -rc '.download.zip.url')
                            FFPROBE_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffprobe/6.0' -fsS | jq -rc '.download.zip.url')
                        else
                            echo "jq is required for Intel Mac installation. Installing with Homebrew..."
                            brew install jq
                            FFMPEG_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffmpeg/6.0' -fsS | jq -rc '.download.zip.url')
                            FFPROBE_URL=$(curl 'https://evermeet.cx/ffmpeg/info/ffprobe/6.0' -fsS | jq -rc '.download.zip.url')
                        fi
                    fi
                    
                    # Download files
                    download_file "$FFMPEG_URL" "$TEMP_DIR/ffmpeg.zip"
                    download_file "$FFPROBE_URL" "$TEMP_DIR/ffprobe.zip"
                    
                    # Extract
                    unzip -o -d "$TEMP_DIR" "$TEMP_DIR/ffmpeg.zip"
                    unzip -o -d "$TEMP_DIR" "$TEMP_DIR/ffprobe.zip"
                    
                    # Install to /usr/local/bin
                    run_sudo mkdir -p /usr/local/bin
                    run_sudo cp "$TEMP_DIR/ffmpeg" /usr/local/bin/
                    run_sudo cp "$TEMP_DIR/ffprobe" /usr/local/bin/
                    run_sudo chmod +x /usr/local/bin/ffmpeg
                    run_sudo chmod +x /usr/local/bin/ffprobe
                    
                    echo "FFmpeg installed successfully for macOS!"
                }

                # Function to install FFmpeg on Linux
                install_linux() {
                    echo "Installing FFmpeg for Linux ($ARCH)..."
                    
                    # Map architecture to johnvansickle.com naming
                    case "$ARCH" in
                        x86_64)
                            ARCH_NAME="amd64"
                            ;;
                        i686|i386)
                            ARCH_NAME="i686"
                            ;;
                        armv6l|armv7l)
                            ARCH_NAME="armhf"
                            ;;
                        aarch64)
                            ARCH_NAME="arm64"
                            ;;
                        *)
                            echo "Unsupported architecture: $ARCH"
                            exit 1
                            ;;
                    esac
                    
                    # URL for the latest release build
                    FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${ARCH_NAME}-static.tar.xz"
                    
                    # Download the file
                    download_file "$FFMPEG_URL" "$TEMP_DIR/ffmpeg.tar.xz"
                    
                    # Extract the archive
                    cd "$TEMP_DIR"
                    tar -xf "ffmpeg.tar.xz"
                    
                    # Find the extracted directory
                    FFMPEG_DIR=$(find . -type d -name "ffmpeg-*-static" | head -n 1)
                    
                    if [ -z "$FFMPEG_DIR" ]; then
                        echo "Error: Could not find extracted FFmpeg directory."
                        exit 1
                    fi
                    
                    # Install to /usr/local/bin
                    run_sudo mkdir -p /usr/local/bin
                    run_sudo cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" /usr/local/bin/
                    run_sudo chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
                    
                    echo "FFmpeg installed successfully for Linux!"
                }

                # Function to install FFmpeg on FreeBSD
                install_freebsd() {
                    echo "Installing FFmpeg for FreeBSD ($ARCH)..."
                    
                    # Currently only supporting x64
                    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "x86_64" ]; then
                        echo "Warning: FreeBSD installation only tested on x64 architecture."
                    fi
                    
                    # URLs from Thefrank's repo
                    FFMPEG_URL="https://github.com/Thefrank/ffmpeg-static-freebsd/releases/download/v6.0.0/ffmpeg"
                    FFPROBE_URL="https://github.com/Thefrank/ffmpeg-static-freebsd/releases/download/v6.0.0/ffprobe"
                    
                    # Download the binaries
                    download_file "$FFMPEG_URL" "$TEMP_DIR/ffmpeg"
                    download_file "$FFPROBE_URL" "$TEMP_DIR/ffprobe"
                    
                    # Install to /usr/local/bin
                    run_sudo mkdir -p /usr/local/bin
                    run_sudo cp "$TEMP_DIR/ffmpeg" /usr/local/bin/
                    run_sudo cp "$TEMP_DIR/ffprobe" /usr/local/bin/
                    run_sudo chmod +x /usr/local/bin/ffmpeg
                    run_sudo chmod +x /usr/local/bin/ffprobe
                    
                    echo "FFmpeg installed successfully for FreeBSD!"
                }

                # Print current ffmpeg version if it exists
                print_current_version() {
                    if command -v ffmpeg &>/dev/null; then
                        echo "Current FFmpeg version:"
                        ffmpeg -version | head -n 2
                    fi
                }

                # System check complete marker
                echo "System check complete"

                # Install based on the detected platform
                print_current_version
                case "$OS" in
                    Darwin)
                        install_macos
                        ;;
                    Linux)
                        # Regular Linux
                        install_linux
                        ;;
                    FreeBSD)
                        install_freebsd
                        ;;
                    *)
                        echo "Unsupported operating system: $OS"
                        exit 1
                        ;;
                esac

                # Verify installation
                if command_exists ffmpeg && command_exists ffprobe; then
                    echo "************************************************"
                    echo "** FFmpeg installation complete!"
                    echo "** FFmpeg version: $(ffmpeg -version | head -n 1)"
                    echo "** FFprobe version: $(ffprobe -version | head -n 1)"
                    echo "************************************************"
                    echo "Successfully installed FFmpeg"
                else
                    echo "Error: Installation verification failed. Please check the logs above."
                    exit 1
                fi

                echo "FFmpeg static installation completed successfully!"
                """
                
                // Write the installation script to a temporary file on the remote server
                installationState.appendOutput("Uploading installation script...")
                
                // Write script to a temporary file on the remote server using command with heredoc
                // Make sure there are no spaces in the path
                let writeCmd = """
                cat > ~/install_ffmpeg.sh << 'ENDOFSCRIPT'
                \(scriptContent)
                ENDOFSCRIPT
                chmod +x ~/install_ffmpeg.sh
                """
                
                let writeOutput = try await client.executeCommand(writeCmd)
                installationState.appendOutput("Script uploaded successfully.")
                
                // Run the installation script with password piping
                installationState.appendOutput("Running installation script...")
                
                // Use a more secure execution method with password piping
                let installCmd = "echo '\(password)' | ~/install_ffmpeg.sh"
                
                installationState.appendOutput("Using \(server.sftpUsesKey ? "provided sudo password" : "SSH password") for installation...")
                
                // Get real-time output by using executeCommandPair with streams
                let execStream = try await client.executeCommandPair(installCmd)
                
                // Process stdout with a single Task to avoid race conditions
                Task {
                    do {
                        var stdoutBuffer = ""
                        var stderrBuffer = ""
                        
                        // Create a task group to handle both streams concurrently
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            // Process stdout
                            group.addTask {
                                for try await data in execStream.stdout {
                                    let chunk = String(buffer: data)
                                    
                                    await MainActor.run {
                                        stdoutBuffer += chunk
                                        
                                        // Process line by line if we have complete lines
                                        let lines = stdoutBuffer.components(separatedBy: "\n")
                                        
                                        // Process all complete lines
                                        if lines.count > 1 {
                                            for i in 0..<lines.count-1 {
                                                let line = lines[i]
                                                installationState.appendOutput(line)
                                                
                                                // Check for completion markers
                                                if line.contains("FFmpeg installation complete") ||
                                                   line.contains("Successfully installed FFmpeg") {
                                                    installationState.installationComplete = true
                                                    server.ffThumb = true
                                                }
                                            }
                                            
                                            // Keep any partial line for next iteration
                                            stdoutBuffer = lines.last ?? ""
                                        }
                                    }
                                }
                                
                                // Process any remaining content
                                if !stdoutBuffer.isEmpty {
                                    await MainActor.run {
                                        installationState.appendOutput(stdoutBuffer)
                                    }
                                }
                            }
                            
                            // Process stderr
                            group.addTask {
                                for try await data in execStream.stderr {
                                    let chunk = String(buffer: data)
                                    
                                    await MainActor.run {
                                        stderrBuffer += chunk
                                        
                                        // Process line by line
                                        let lines = stderrBuffer.components(separatedBy: "\n")
                                        
                                        // Process all complete lines
                                        if lines.count > 1 {
                                            for i in 0..<lines.count-1 {
                                                let line = lines[i]
                                                if !line.isEmpty {
                                                    installationState.appendOutput("ERROR: \(line)")
                                                }
                                            }
                                            
                                            // Keep any partial line for next iteration
                                            stderrBuffer = lines.last ?? ""
                                        }
                                    }
                                }
                                
                                // Process any remaining content
                                if !stderrBuffer.isEmpty && !stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    await MainActor.run {
                                        installationState.appendOutput("ERROR: \(stderrBuffer)")
                                    }
                                }
                            }
                            
                            // Wait for both stream processing tasks to complete
                            try await group.waitForAll()
                        }
                        
                        // Wait for the command to complete
                        installationState.appendOutput("Waiting for installation to complete...")
                        
                        // Clean up the temporary script after execution completes
                        let cleanupCmd = "rm -f ~/install_ffmpeg.sh"
                        let _ = try await client.executeCommand(cleanupCmd)
                        installationState.appendOutput("Cleaned up temporary files")
                        
                        // Final verification if needed
                        if !installationState.installationComplete {
                            let verifyResult = try await client.executeCommand("which ffmpeg ffprobe || echo 'Not found'")
                            let verifyOutput = String(buffer: verifyResult).trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            if !verifyOutput.contains("Not found") {
                                installationState.appendOutput("\nVerification successful - FFmpeg and FFprobe are installed!")
                                
                                await MainActor.run {
                                    server.ffThumb = true
                                    installationState.installationComplete = true
                                }
                            } else {
                                installationState.appendOutput("\nWarning: Verification failed. FFmpeg and/or FFprobe may not be in the PATH.")
                            }
                        }
                        
                    } catch {
                        installationState.appendOutput("Error processing command output: \(error.localizedDescription)")
                    }
                }
                
            } else {
                // If uname doesn't work, try Windows detection
                let osInfoCmd = "powershell -Command \"Write-Output 'Windows'\" 2>/dev/null || echo \"Unknown\""
                let osInfoResult = try await client.executeCommand(osInfoCmd)
                let osInfo = String(buffer: osInfoResult).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if osInfo.contains("Windows") {
                    installationState.appendOutput("Detected Windows Operating System")
                    // Windows-specific installation
                    await performWindowsInstallation(client: client, password: password)
                } else {
                    installationState.appendOutput("Unable to definitively determine OS type. Defaulting to Linux-like system.")
                    installationState.appendOutput("Will attempt generic Unix installation...")
                    
                    // Add generic Unix installation code here if needed
                    // This would be similar to the Linux installation path above
                }
            }
            
        } catch {
            installationState.appendOutput("\nInstallation error: \(error)")
            
            // Make sure to set isInstalling to false on error
            await MainActor.run {
                installationState.isInstalling = false
            }
        }
    }
    
    private func performWindowsInstallation(client: SSHClient, password: String) async {
        do {
            installationState.appendOutput("Detected Windows system. Using Windows-specific FFmpeg installation...")
            
            // Check if PowerShell is available
            let powershellCmd = "powershell -Command \"Write-Output 'PowerShell is available'\""
            let psResult = try await client.executeCommand(powershellCmd)
            let psOutput = String(buffer: psResult).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !psOutput.contains("PowerShell is available") {
                installationState.appendOutput("Error: PowerShell is not available on this Windows system. It's required for FFmpeg installation.")
                return
            }
            
            installationState.appendOutput("PowerShell is available. Proceeding with installation...")
            
            // Check if FFmpeg is already installed
            let checkFFmpegCmd = "powershell -Command \"try { Get-Command ffmpeg -ErrorAction Stop; Write-Output 'FFmpeg is already installed'; } catch { Write-Output 'FFmpeg is not installed'; }\""
            let checkResult = try await client.executeCommand(checkFFmpegCmd)
            let checkOutput = String(buffer: checkResult).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if checkOutput.contains("FFmpeg is already installed") {
                installationState.appendOutput("FFmpeg is already installed on this system.")
                
                // Get the installed version
                let versionCmd = "powershell -Command \"try { (ffmpeg -version)[0]; } catch { Write-Output 'Unable to get version'; }\""
                let versionResult = try await client.executeCommand(versionCmd)
                let versionOutput = String(buffer: versionResult).trimmingCharacters(in: .whitespacesAndNewlines)
                
                installationState.appendOutput("Current FFmpeg version: \(versionOutput)")
                installationState.appendOutput("Installation skipped as FFmpeg is already installed.")
                
                await MainActor.run {
                    server.ffThumb = true
                    installationState.installationComplete = true
                }
                return
            }
            
            installationState.appendOutput("FFmpeg is not installed. Preparing to install...")
            
            // Inform user that we need to provide manual installation instructions
            installationState.appendOutput("\n---------------------------------------------------")
            installationState.appendOutput("WINDOWS INSTALLATION INSTRUCTIONS")
            installationState.appendOutput("---------------------------------------------------")
            installationState.appendOutput("For Windows systems, administrator privileges are required.")
            installationState.appendOutput("Please run the following command in PowerShell with admin privileges:")
            installationState.appendOutput("[Copy Windows Install Command]")
            installationState.appendOutput("\nThis command will:")
            installationState.appendOutput("1. Download the latest FFmpeg build")
            installationState.appendOutput("2. Extract it to C:\\FFmpeg\\bin")
            installationState.appendOutput("3. Add FFmpeg to your system PATH")
            installationState.appendOutput("\nAfter running the command, restart your terminal and run 'ffmpeg -version' to verify the installation.")
            installationState.appendOutput("---------------------------------------------------")
            
            // We can't automatically install it, so we'll mark as incomplete
            installationState.appendOutput("\nNOTE: Due to Windows security restrictions, automatic installation cannot be completed.")
            installationState.appendOutput("Please follow the manual instructions above to complete the installation.")
            
        } catch {
            installationState.appendOutput("Error during Windows installation preparation: \(error.localizedDescription)")
        }
    }
}
#endif
