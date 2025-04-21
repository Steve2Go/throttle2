import Foundation
import Citadel
import KeychainAccess
import SwiftUI

/// Manages HTTP streaming server using miniserve on the remote server
class HttpStreamingManager {
    static let shared = HttpStreamingManager()
    
    // Default port range - can be modified in app settings
    @AppStorage("StreamingServerBasePort") private var serverBasePort = 8723
    
    // Active streaming instances by username
    private var activeInstances: [String: StreamingInstance] = [:]
    
    // Structure to track active streaming instances
    private struct StreamingInstance {
        let username: String
        let port: Int
        let rootDirectory: String
        var httpPassword: String
        //var ffmpegInstalled: Bool
    }
    
    private init() {}
    
    /// Set up the miniserve streaming server for a specific user
    func setupServer(for server: ServerEntity) async throws {
        print("Setting up HTTP streaming server for: \(server.name ?? "unknown")")
        
        guard let username = server.sftpUser else {
            throw StreamingError.missingCredentials
        }
        
        // Connect to the server via SSH
        let sshClient = try await connectToServer(server: server)
        
        // Check & install miniserve if needed
        try await installMiniserveIfNeeded(sshClient: sshClient)
        
        
        // Calculate a port number based on the username (for consistent port allocation)
        let port = calculatePortForUser(username: username)
        
        // Always use root directory as the base
        let rootDirectory = "/"
        
        // Generate a random password for HTTP auth (or retrieve existing one)
        let httpPassword = try await getOrCreateHttpPassword(sshClient: sshClient, username: username)
        
        // Start miniserve on the remote server with the specified root directory
        try await startStreamingServer(
            sshClient: sshClient,
            server: server,
            port: port,
            rootDirectory: rootDirectory,
            httpPassword: httpPassword
        )
        
        // Store the active instance
        let instance = StreamingInstance(
            username: username,
            port: port,
            rootDirectory: rootDirectory,
            httpPassword: httpPassword
            //ffmpegInstalled: false
        )
        activeInstances[username] = instance
        
        // Close the SSH client after setup
        try await sshClient.close()
        
        print("HTTP streaming server setup complete for user \(username) on port \(port)")
    }
    
    /// Stop the streaming server for a specific user
    func stopServer(for server: ServerEntity) async {
        print("Stopping HTTP streaming server for: \(server.name ?? "unknown")")
        
        guard let username = server.sftpUser else {
            print("Missing username, cannot stop server")
            return
        }
        
        // Check if this user has an active instance
        guard let instance = activeInstances[username] else {
            print("No active streaming instance found for \(username)")
            return
        }
        
        do {
            let sshClient = try await connectToServer(server: server)
            // Get the absolute home directory path
            let userHome = try await getUserHomeDirectory(sshClient: sshClient)
            let userInstallDir = "\(userHome)/throttle-streaming"
            
            let stopCommand = "\(userInstallDir)/stop-streaming.sh \(instance.port)"
            _ = try await sshClient.executeCommand(stopCommand)
            try await sshClient.close()
            
            // Remove from active instances
            activeInstances.removeValue(forKey: username)
            
            print("HTTP streaming server stopped for user \(username)")
        } catch {
            print("Error stopping streaming server: \(error.localizedDescription)")
        }
    }
    
    /// Get the port for a specific user's streaming server
    func getServerPort(for username: String) -> Int? {
        return activeInstances[username]?.port
    }
    
    /// Check if FFmpeg is installed for a specific user
//    func isFFmpegInstalled(for username: String) -> Bool {
//        return activeInstances[username]?.ffmpegInstalled ?? false
//    }
    
    /// Create a streaming URL from a file path and local port with authentication management
    /// Create a streaming URL from a file path and local port with authentication management
    func createStreamingURL(for filePath: String, server: ServerEntity, localPort: Int, forceRefresh: Bool = false) async throws -> URL? {
        guard let username = server.sftpUser else {
            print("Missing username for streaming URL")
            return nil
        }
        
        // Get HTTP password - with optional refresh from server
        let httpPassword: String
        
        if forceRefresh {
            // Force refresh password from server
            guard let refreshedPassword = try await refreshHttpPassword(for: server) else {
                print("Failed to refresh HTTP password for \(username)")
                return nil
            }
            httpPassword = refreshedPassword
        } else {
            // Try to get from keychain first
            let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
            let passwordKey = "httpPassword\(username)"
            
            if let savedPassword = keychain[passwordKey] {
                httpPassword = savedPassword
            } else if let instance = activeInstances[username] {
                // Try in-memory cache as fallback
                httpPassword = instance.httpPassword
                // Save to keychain for next time
                keychain[passwordKey] = instance.httpPassword
            } else {
                // As last resort, fetch from server
                guard let fetchedPassword = try await refreshHttpPassword(for: server) else {
                    print("No HTTP password available for \(username)")
                    return nil
                }
                httpPassword = fetchedPassword
            }
        }
        
        // Ensure the path starts with a /
        let cleanPath = filePath.starts(with: "/") ? filePath : "/" + filePath
        
        // Define a custom set of allowed characters for path encoding
        // This extends the default .urlPathAllowed to handle more special characters
        var allowedPathChars = CharacterSet.urlPathAllowed
        // Remove characters that need to be percent-encoded in paths
        allowedPathChars.remove(charactersIn: "[]@!$&'()*+,;=")
        
        // URL encode the path with our extended character set
        guard let encodedPath = cleanPath.addingPercentEncoding(withAllowedCharacters: allowedPathChars) else {
            print("Failed to encode path: \(cleanPath)")
            return nil
        }
        
        // Create a custom character set for username encoding
        var allowedUsernameChars = CharacterSet.alphanumerics
        allowedUsernameChars.insert(charactersIn: "-._~") // RFC 3986 unreserved characters
        
        // Create a custom character set for password encoding
        // Passwords need careful encoding as they might contain many special characters
        var allowedPasswordChars = CharacterSet.alphanumerics
        allowedPasswordChars.insert(charactersIn: "-._~") // RFC 3986 unreserved characters
        
        // URL encode credentials for basic auth with our custom character sets
        guard let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: allowedUsernameChars),
              let encodedPassword = httpPassword.addingPercentEncoding(withAllowedCharacters: allowedPasswordChars) else {
            print("Failed to encode credentials")
            return nil
        }
        
        // Create the URL with basic auth credentials
        let urlString = "http://\(encodedUsername):\(encodedPassword)@localhost:\(localPort)\(encodedPath)"
        
        // Validate the created URL
        guard let url = URL(string: urlString) else {
            print("Failed to create URL from string: \(urlString)")
            return nil
        }
        
        return url
    }
  
    
    /// Public method to handle authentication failures and refresh the password
    func handleAuthFailure(for server: ServerEntity) async throws -> Bool {
        guard let username = server.sftpUser else {
            return false
        }
        
        print("Authentication failure detected for user \(username), refreshing password...")
        
        // Try to refresh the password from the server
        if let _ = try await refreshHttpPassword(for: server) {
            print("Successfully refreshed HTTP password for \(username)")
            return true
        }
        
        return false
    }
    
    /// Refresh HTTP password by fetching it from the server
    func refreshHttpPassword(for server: ServerEntity) async throws -> String? {
        guard let username = server.sftpUser else {
            return nil
        }
        
        // Force a fresh connection to get the latest password
        let sshClient = try await connectToServer(server: server)
        defer {
            Task {
                try? await sshClient.close()
            }
        }
        
        // Get the password from the file on the server
        let password = try await getOrCreateHttpPassword(sshClient: sshClient, username: username)
        
        // Update keychain with the refreshed password
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        let passwordKey = "httpPassword\(username)"
        keychain[passwordKey] = password
        
        // Update our in-memory cache if needed
        if var instance = activeInstances[username] {
            instance.httpPassword = password
            activeInstances[username] = instance
        }
        
        print("HTTP password refreshed from server for user \(username)")
        return password
    }
    
    /// Get HTTP password for a specific user
    func getHttpPassword(for server: ServerEntity) async throws -> String? {
        guard let username = server.sftpUser else {
            return nil
        }
        
        // Check if we already have the password in memory
        if let instance = activeInstances[username] {
            return instance.httpPassword
        }
        
        // Otherwise, retrieve it from the server
        let sshClient = try await connectToServer(server: server)
        defer {
            Task {
                try? await sshClient.close()
            }
        }
        
        return try await getOrCreateHttpPassword(sshClient: sshClient, username: username)
    }
    
    
    /// Calculate a consistent port number for a user
    private func calculatePortForUser(username: String) -> Int {
        // Simple hash function to generate a port offset (0-1000) based on username
        let hash = username.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let portOffset = hash % 1000
        return serverBasePort + portOffset
    }
    
    /// Ensure the directory path is properly formatted
    private func formatDirectoryPath(_ path: String) -> String {
        var formattedPath = path
        
        // Make sure it ends with a slash
        if !formattedPath.hasSuffix("/") {
            formattedPath += "/"
        }
        
        return formattedPath
    }
    
    /// Connect to the SSH server
    private func connectToServer(server: ServerEntity) async throws -> SSHClient {
        guard let hostname = server.sftpHost,
              let username = server.sftpUser,
              let password = getPassword(for: server) else {
            throw StreamingError.missingCredentials
        }
        
        return try await SSHClient.connect(
            host: hostname,
            port: Int(server.sftpPort),
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }
    
    /// Get password for a server from keychain
    private func getPassword(for server: ServerEntity) -> String? {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        return keychain["sftpPassword" + (server.name ?? "")]
    }
    
    /// Get the user's home directory as an absolute path
    private func getUserHomeDirectory(sshClient: SSHClient) async throws -> String {
        let command = "echo $HOME"
        let output = try await sshClient.executeCommand(command)
        let homePath = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        return homePath
    }
    
    /// Get the current username
    private func getCurrentUsername(sshClient: SSHClient) async throws -> String {
        let command = "whoami"
        let output = try await sshClient.executeCommand(command)
        let username = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        return username
    }
    
    /// Generate a random password or retrieve an existing one
    private func getOrCreateHttpPassword(sshClient: SSHClient, username: String) async throws -> String {
        let userHome = try await getUserHomeDirectory(sshClient: sshClient)
        let userInstallDir = "\(userHome)/throttle-streaming"
        let passwordFile = "\(userInstallDir)/http_password.txt"
        
        // Check if password file exists
        let checkCommand = "[ -f \(passwordFile) ] && echo 'EXISTS' || echo 'NOT_EXISTS'"
        let output = try await sshClient.executeCommand(checkCommand)
        let outputStr = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if outputStr == "EXISTS" {
            // Read existing password
            let readCommand = "cat \(passwordFile)"
            let passwordOutput = try await sshClient.executeCommand(readCommand)
            let password = String(buffer: passwordOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !password.isEmpty {
                print("Retrieved existing HTTP password for user \(username)")
                return password
            }
        }
        
        // Generate a new password (20 character random string)
        let generateCommand = "openssl rand -base64 15 | tr -d '/+=' | cut -c1-20"
        let passwordOutput = try await sshClient.executeCommand(generateCommand)
        let password = String(buffer: passwordOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Save password to file with secure permissions
        let saveCommand = "mkdir -p \(userInstallDir) && echo '\(password)' > \(passwordFile) && chmod 600 \(passwordFile)"
        _ = try await sshClient.executeCommand(saveCommand)
        
        print("Generated and stored new HTTP password for user \(username)")
        return password
    }
    
    /// Install miniserve if needed
    private func installMiniserveIfNeeded(sshClient: SSHClient) async throws {
        guard let username = try? await getCurrentUsername(sshClient: sshClient) else {
            throw StreamingError.installationFailed("Could not determine current username")
        }
        
        // Use user's home directory for the installation - absolute path to avoid tilde expansion issues
        let userHome = try await getUserHomeDirectory(sshClient: sshClient)
        let userInstallDir = "\(userHome)/throttle-streaming"
        
        // Create the directory if it doesn't exist
        let mkdirCmd = "mkdir -p \(userInstallDir)"
        _ = try await sshClient.executeCommand(mkdirCmd)
        
        // Check if miniserve is already installed for this user
        let checkCommand = "[ -f \(userInstallDir)/miniserve ] && echo 'EXISTS' || echo 'NOT_EXISTS'"
        let output = try await sshClient.executeCommand(checkCommand)
        let outputStr = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if outputStr == "EXISTS" {
            print("Miniserve is already installed in user's home directory")
            return
        }
        
        print("Installing miniserve in user's home directory...")
        
        // Upload and run the installation script for this user
        try await uploadAndRunInstallScript(sshClient: sshClient, installDir: userInstallDir)
    }
    
    /// Start the miniserve streaming server
    private func startStreamingServer(
        sshClient: SSHClient,
        server: ServerEntity,
        port: Int,
        rootDirectory: String,
        httpPassword: String
    ) async throws {
        // Format the directory path
        let formattedRootDirectory = formatDirectoryPath(rootDirectory)
        
        // Get authentication info
        guard let username = server.sftpUser else {
            throw StreamingError.missingCredentials
        }
        
        // Get the absolute home directory path
        let userHome = try await getUserHomeDirectory(sshClient: sshClient)
        let userInstallDir = "\(userHome)/throttle-streaming"
        
        // Stop any existing server on this port
        let stopCommand = "\(userInstallDir)/stop-streaming.sh \(port)"
        _ = try await sshClient.executeCommand(stopCommand)
        
        // Check if miniserve exists and is executable
        let checkCommand = "ls -la \(userInstallDir)/miniserve || echo 'FILE_NOT_FOUND'"
        let checkOutput = try await sshClient.executeCommand(checkCommand)
        let checkResult = String(buffer: checkOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if checkResult.contains("FILE_NOT_FOUND") {
            print("Error: miniserve binary not found. Installation may have failed.")
            throw StreamingError.serverStartFailed("Miniserve binary not found at \(userInstallDir)/miniserve")
        }
        
        print("Miniserve binary check: \(checkResult)")
        
        // Create auth file for basic authentication using the random password
        let authFilePath = "\(userInstallDir)/auth_\(username).txt"
        let createAuthCommand = "echo '\(username):\(httpPassword)' > \(authFilePath) && chmod 600 \(authFilePath)"
        _ = try await sshClient.executeCommand(createAuthCommand)
        
        // Try running with more debug output
        let startCommand = "sh -x \(userInstallDir)/start-streaming.sh \(port) '\(formattedRootDirectory)' '\(userInstallDir)/miniserve.log' '\(authFilePath)' 2>&1"
        let output = try await sshClient.executeCommand(startCommand)
        let outputStr = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("Start command full output: \(outputStr)")
        
        // Check if server started successfully
        if !outputStr.contains("SUCCESS:") {
            // If failed, check what's in the log file
            let logCommand = "cat \(userInstallDir)/miniserve.log || echo 'NO_LOG_FILE'"
            let logOutput = try await sshClient.executeCommand(logCommand)
            let logResult = String(buffer: logOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            
            print("Miniserve log: \(logResult)")
            
            throw StreamingError.serverStartFailed("Failed to start server. Output: \(outputStr). Log: \(logResult)")
        }
        
        // Verify the server is actually running
        let psCommand = "ps -ef | grep miniserve | grep -v grep || echo 'NOT_RUNNING'"
        let psOutput = try await sshClient.executeCommand(psCommand)
        let psResult = String(buffer: psOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if psResult.contains("NOT_RUNNING") {
            print("Error: miniserve process not found after starting.")
            throw StreamingError.serverStartFailed("Process not running after start")
        }
        
        print("Miniserve process: \(psResult)")
        print("HTTP streaming server started successfully on port \(port) for user \(username)")
    }
    
    /// Upload and run the miniserve installation script
    private func uploadAndRunInstallScript(sshClient: SSHClient, installDir: String) async throws {
        // The installation script content - modified to use absolute paths
        let installScript = """
        #!/bin/bash
        # Miniserve Static Binary Installer for Throttle 2
        set -e

        # Create the directory for Throttle streaming
        THROTTLE_DIR="\(installDir)"
        mkdir -p "$THROTTLE_DIR"
        echo "Using directory: $THROTTLE_DIR"

        # Detect OS and architecture
        OS="$(uname -s)"
        ARCH="$(uname -m)"
        echo "Detected: $OS - $ARCH"

        # Map architecture to miniserve naming
        case "$ARCH" in
            x86_64) ARCH_NAME="x86_64" ;;
            amd64) ARCH_NAME="x86_64" ;;
            aarch64) ARCH_NAME="aarch64" ;;
            arm64) ARCH_NAME="aarch64" ;;
            armv7*) ARCH_NAME="armv7" ;;
            *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
        esac

        # Map OS to miniserve naming
        case "$OS" in
            Linux) OS_NAME="unknown-linux-musl" ;;
            Darwin) OS_NAME="apple-darwin" ;;
            FreeBSD) OS_NAME="unknown-freebsd" ;;
            *) echo "Unsupported OS: $OS"; exit 1 ;;
        esac

        # Set miniserve version and URL
        MINISERVE_VERSION="0.24.0"
        MINISERVE_BINARY="miniserve-${MINISERVE_VERSION}-${ARCH_NAME}-${OS_NAME}"
        MINISERVE_URL="https://github.com/svenstaro/miniserve/releases/download/v${MINISERVE_VERSION}/${MINISERVE_BINARY}"
        MINISERVE_PATH="${THROTTLE_DIR}/miniserve"

        echo "Downloading from: $MINISERVE_URL"
        echo "Saving to: $MINISERVE_PATH"

        # Download using curl or wget
        if command -v curl >/dev/null 2>&1; then
            echo "Downloading miniserve using curl..."
            curl -L -v -o "$MINISERVE_PATH" "$MINISERVE_URL"
            curl_exit=$?
            echo "curl exit code: $curl_exit"
            if [ $curl_exit -ne 0 ]; then
                echo "curl download failed. Trying wget..."
                if command -v wget >/dev/null 2>&1; then
                    wget -v -O "$MINISERVE_PATH" "$MINISERVE_URL"
                else
                    echo "Neither curl nor wget available or working"
                    exit 1
                fi
            fi
        elif command -v wget >/dev/null 2>&1; then
            echo "Downloading miniserve using wget..."
            wget -v -O "$MINISERVE_PATH" "$MINISERVE_URL"
        else
            echo "Error: Neither curl nor wget available"
            exit 1
        fi

        # Check if file exists and has size > 0
        if [ ! -s "$MINISERVE_PATH" ]; then
            echo "Downloaded file is empty or doesn't exist!"
            ls -la "$THROTTLE_DIR"
            exit 1
        fi

        # Make executable and secure permissions
        chmod 700 "$MINISERVE_PATH"
        echo "Made executable with user-only permissions: $MINISERVE_PATH"
        ls -la "$MINISERVE_PATH"

        # Test executable
        echo "Testing miniserve binary..."
        "$MINISERVE_PATH" --version
        test_exit=$?
        echo "Test exit code: $test_exit"
        if [ $test_exit -ne 0 ]; then
            echo "Binary test failed!"
            exit 1
        fi

        # Create start script - using absolute HOME path
        cat > "${THROTTLE_DIR}/start-streaming.sh" << 'EOL'
        #!/bin/bash
        # Script to start miniserve with appropriate options
        PORT="$1"
        DIR_TO_SERVE="$2"
        LOGFILE="${3:-$HOME/throttle-streaming/miniserve.log}"
        AUTH_FILE="$4"

        # Ensure directory exists
        if [ ! -d "$DIR_TO_SERVE" ]; then
            echo "Error: Directory not found: $DIR_TO_SERVE"
            exit 1
        fi

        # Make sure FFmpeg is in the PATH
        export PATH="$HOME/bin:$PATH"

        # Kill any existing instance
        pkill -f "miniserve.*--port $PORT" || true
        
        # Start miniserve with the correct parameters
        if [ -f "$AUTH_FILE" ]; then
            echo "Starting with authentication file: $AUTH_FILE"
            USERNAME=$(head -n1 "$AUTH_FILE" | cut -d: -f1)
            PASSWORD=$(head -n1 "$AUTH_FILE" | cut -d: -f2)
            
            # Set up routes for thumbnails
            THUMB_ROUTE="/thumb/"
            
            $HOME/throttle-streaming/miniserve \
              "$DIR_TO_SERVE" \
              --port "$PORT" \
              --interfaces 127.0.0.1 \
              --media-type image \
              --media-type video \
              --media-type audio \
              --upload-files \
              --auth "$USERNAME:$PASSWORD" \
              --index index.html \
              --verbose >> "$LOGFILE" 2>&1 &
        else
            echo "No auth file specified, starting without authentication"
            $HOME/throttle-streaming/miniserve \
              "$DIR_TO_SERVE" \
              --port "$PORT" \
              --interfaces 127.0.0.1 \
              --media-type image \
              --media-type video \
              --media-type audio \
              --upload-files \
              --index index.html \
              --verbose >> "$LOGFILE" 2>&1 &
        fi

        # Save PID
        echo $! > "$HOME/throttle-streaming/miniserve-${PORT}.pid"
        sleep 1

        # Check if running
        if kill -0 $! 2>/dev/null; then
            echo "Miniserve started on port $PORT, serving $DIR_TO_SERVE"
            echo "SUCCESS:$PORT:$!"
            exit 0
        else
            echo "Failed to start miniserve"
            cat "$LOGFILE"
            exit 1
        fi
        EOL
        chmod 700 "${THROTTLE_DIR}/start-streaming.sh"
        echo "Created start script with secure permissions"

        # Create stop script - using absolute HOME path
        cat > "${THROTTLE_DIR}/stop-streaming.sh" << 'EOL'
        #!/bin/bash
        # Script to stop miniserve
        PORT="$1"
        PID_FILE="$HOME/throttle-streaming/miniserve-${PORT}.pid"

        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            if kill -0 "$PID" 2>/dev/null; then
                echo "Stopping miniserve on port $PORT (PID: $PID)"
                kill "$PID"
                rm "$PID_FILE"
                echo "Stopped miniserve successfully"
            else
                echo "Miniserve not running (PID: $PID)"
                rm "$PID_FILE"
            fi
        else
            # Try to find by port
            pkill -f "miniserve.*--port $PORT" || true
        fi
        EOL
        chmod 700 "${THROTTLE_DIR}/stop-streaming.sh"
        echo "Created stop script with secure permissions"

        echo "Miniserve setup completed successfully in user's home directory!"
        echo "SUCCESS"
        """
        
        // Get the user's home directory to save the installation script
        let userHome = try await getUserHomeDirectory(sshClient: sshClient)
        let scriptPath = "\(userHome)/install-miniserve.sh"
        
        // Write the script to a temporary file in the user's home directory
        let writeCommand = """
        cat > \(scriptPath) << 'ENDOFSCRIPT'
        \(installScript)
        ENDOFSCRIPT
        chmod 700 \(scriptPath)
        """
        _ = try await sshClient.executeCommand(writeCommand)
        
        // Execute the script
        let execCommand = "bash -x \(scriptPath) 2>&1"
        let execOutput = try await sshClient.executeCommand(execCommand)
        let execOutputStr = String(buffer: execOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("Installation script full output: \(execOutputStr)")
        
        // Clean up
        _ = try await sshClient.executeCommand("rm -f \(scriptPath)")
        
        // Check for success
        if !execOutputStr.contains("SUCCESS") {
            throw StreamingError.installationFailed(execOutputStr)
        }
        
        print("Miniserve installed successfully in user's home directory")
    }
    
    // MARK: - Error Types
    
    enum StreamingError: Error, LocalizedError {
        case missingCredentials
        case connectionFailed
        case installationFailed(String)
        case serverStartFailed(String)
        case invalidURL
        
        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Missing server credentials"
            case .connectionFailed:
                return "Failed to connect to server"
            case .installationFailed(let details):
                return "Failed to install streaming server: \(details)"
            case .serverStartFailed(let details):
                return "Failed to start streaming server: \(details)"
            case .invalidURL:
                return "Invalid URL for streaming"
            }
        }
    }
}
