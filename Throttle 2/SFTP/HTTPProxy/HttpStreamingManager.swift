import Foundation
import Citadel
import KeychainAccess
import SwiftUI

/// Manages HTTP streaming server using miniserve on the remote server
class HttpStreamingManager {
    static let shared = HttpStreamingManager()
    
    // Default port - can be modified in app settings
    @AppStorage("StreamingServerPort") private var serverPort = 8723
    
    private init() {}
    
    /// Set up the miniserve streaming server
    func setupServer(for server: ServerEntity) async throws {
        print("Setting up HTTP streaming server for: \(server.name ?? "unknown")")
        
        // Connect to the server via SSH
        let sshClient = try await connectToServer(server: server)
        
        // Check & install miniserve if needed
        try await installMiniserveIfNeeded(sshClient: sshClient)
        
        // Start miniserve on the remote server
        try await startStreamingServer(sshClient: sshClient, server: server)
        
        // Close the SSH client after setup
        try await sshClient.close()
        
        print("HTTP streaming server setup complete")
    }
    
    /// Stop the streaming server
    func stopServer(for server: ServerEntity) async {
        print("Stopping HTTP streaming server for: \(server.name ?? "unknown")")
        
        do {
            let sshClient = try await connectToServer(server: server)
            let stopCommand = "/tmp/throttle-streaming/stop-streaming.sh \(serverPort)"
            _ = try await sshClient.executeCommand(stopCommand)
            try await sshClient.close()
            print("HTTP streaming server stopped")
        } catch {
            print("Error stopping streaming server: \(error.localizedDescription)")
        }
    }
    
    /// Get the port the streaming server is running on
    func getServerPort() -> Int {
        return serverPort
    }
    
    /// Create a streaming URL from a file path and local port
    func createStreamingURL(for filePath: String, server: ServerEntity, localPort: Int) -> URL? {
        // Convert path to URL
        var relativeFilePath = filePath
        
        // Remove the base directory prefix if it exists
        let baseDir = server.pathServer ?? "/"
        if relativeFilePath.starts(with: baseDir) {
            relativeFilePath = String(relativeFilePath.dropFirst(baseDir.count))
        }
        
        // Ensure the path starts with a /
        if !relativeFilePath.starts(with: "/") {
            relativeFilePath = "/" + relativeFilePath
        }
        
        // URL encode the path
        let encodedPath = relativeFilePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativeFilePath
        
        // Create the URL
        let urlString = "http://localhost:\(localPort)\(encodedPath)"
        return URL(string: urlString)
    }
    
    // MARK: - Private Methods
    
    /// Connect to the SSH server
    private func connectToServer(server: ServerEntity) async throws -> SSHClient {
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let hostname = server.sftpHost,
              let username = server.sftpUser,
              let password = keychain["sftpPassword" + (server.name ?? "")] else {
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
    
    /// Install miniserve if needed
    private func installMiniserveIfNeeded(sshClient: SSHClient) async throws {
        // Check if miniserve is already installed
        let checkCommand = "[ -f /tmp/throttle-streaming/miniserve ] && echo 'EXISTS' || echo 'NOT_EXISTS'"
        let output = try await sshClient.executeCommand(checkCommand)
        let outputStr = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if outputStr == "EXISTS" {
            print("Miniserve is already installed")
            return
        }
        
        print("Installing miniserve...")
        
        // Upload and run the installation script
        try await uploadAndRunInstallScript(sshClient: sshClient)
    }
    
    /// Start the miniserve streaming server
    private func startStreamingServer(sshClient: SSHClient, server: ServerEntity) async throws {
        // Determine directory to serve
        let directoryToServe = server.pathServer ?? "/"
        
        // Stop any existing server
        let stopCommand = "/tmp/throttle-streaming/stop-streaming.sh \(serverPort)"
        _ = try await sshClient.executeCommand(stopCommand)
        
        // Check if miniserve exists and is executable
        let checkCommand = "ls -la /tmp/throttle-streaming/miniserve || echo 'FILE_NOT_FOUND'"
        let checkOutput = try await sshClient.executeCommand(checkCommand)
        let checkResult = String(buffer: checkOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if checkResult.contains("FILE_NOT_FOUND") {
            print("Error: miniserve binary not found. Installation may have failed.")
            throw StreamingError.serverStartFailed("Miniserve binary not found")
        }
        
        print("Miniserve binary check: \(checkResult)")
        
        // Verify miniserve can run
        let testCommand = "/tmp/throttle-streaming/miniserve --version || echo 'EXECUTION_FAILED'"
        let testOutput = try await sshClient.executeCommand(testCommand)
        let testResult = String(buffer: testOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if testResult.contains("EXECUTION_FAILED") {
            print("Error: miniserve binary exists but cannot be executed.")
            throw StreamingError.serverStartFailed("Miniserve cannot be executed")
        }
        
        print("Miniserve version check: \(testResult)")
        
        // Try running with more debug output
        let startCommand = "sh -x /tmp/throttle-streaming/start-streaming.sh \(serverPort) '\(directoryToServe)' 2>&1"
        let output = try await sshClient.executeCommand(startCommand)
        let outputStr = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("Start command full output: \(outputStr)")
        
        // Check if server started successfully
        if !outputStr.contains("SUCCESS:") {
            // If failed, check what's in the log file
            let logCommand = "cat /tmp/throttle-streaming/miniserve.log || echo 'NO_LOG_FILE'"
            let logOutput = try await sshClient.executeCommand(logCommand)
            let logResult = String(buffer: logOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            
            print("Miniserve log: \(logResult)")
            
            throw StreamingError.serverStartFailed(outputStr)
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
        print("HTTP streaming server started successfully")
    }
    
    /// Upload and run the miniserve installation script
    private func uploadAndRunInstallScript(sshClient: SSHClient) async throws {
        // The installation script content
        let installScript = """
        #!/bin/bash
        # Miniserve Static Binary Installer for Throttle 2
        set -e

        # Create a temporary directory for Throttle streaming
        THROTTLE_TEMP_DIR="/tmp/throttle-streaming"
        mkdir -p "$THROTTLE_TEMP_DIR"
        echo "Using directory: $THROTTLE_TEMP_DIR"

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
        MINISERVE_PATH="${THROTTLE_TEMP_DIR}/miniserve"

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
            ls -la "$THROTTLE_TEMP_DIR"
            exit 1
        fi

        # Make executable
        chmod +x "$MINISERVE_PATH"
        echo "Made executable: $MINISERVE_PATH"
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

        # Create start script
        cat > "${THROTTLE_TEMP_DIR}/start-streaming.sh" << 'EOL'
        #!/bin/bash
        # Script to start miniserve with appropriate options
        PORT="$1"
        DIR_TO_SERVE="$2"
        LOGFILE="${3:-/tmp/throttle-streaming/miniserve.log}"

        # Ensure directory exists
        if [ ! -d "$DIR_TO_SERVE" ]; then
            echo "Error: Directory not found: $DIR_TO_SERVE"
            exit 1
        fi

        # Kill any existing instance
        pkill -f "miniserve.*--port $PORT" || true
        
        # Start miniserve with the correct parameters based on help output
        /tmp/throttle-streaming/miniserve \
          "$DIR_TO_SERVE" \
          --port "$PORT" \
          --interfaces 127.0.0.1 \
          --media-type image \
          --media-type video \
          --media-type audio \
          --upload-files \
          --index index.html \
          --verbose >> "$LOGFILE" 2>&1 &

        # Save PID
        echo $! > "/tmp/throttle-streaming/miniserve-${PORT}.pid"
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
        chmod +x "${THROTTLE_TEMP_DIR}/start-streaming.sh"
        echo "Created start script"

        # Create stop script
        cat > "${THROTTLE_TEMP_DIR}/stop-streaming.sh" << 'EOL'
        #!/bin/bash
        # Script to stop miniserve
        PORT="$1"
        PID_FILE="/tmp/throttle-streaming/miniserve-${PORT}.pid"

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
        chmod +x "${THROTTLE_TEMP_DIR}/stop-streaming.sh"
        echo "Created stop script"

        echo "Miniserve setup completed successfully!"
        echo "SUCCESS"
        """
        
        // Write the script to a temporary file on the remote server
        let writeCommand = """
        cat > /tmp/install-miniserve.sh << 'ENDOFSCRIPT'
        \(installScript)
        ENDOFSCRIPT
        chmod +x /tmp/install-miniserve.sh
        """
        _ = try await sshClient.executeCommand(writeCommand)
        
        // Execute the script
        let execCommand = "bash -x /tmp/install-miniserve.sh 2>&1"
        let execOutput = try await sshClient.executeCommand(execCommand)
        let execOutputStr = String(buffer: execOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("Installation script full output: \(execOutputStr)")
        
        // Clean up
        _ = try await sshClient.executeCommand("rm -f /tmp/install-miniserve.sh")
        
        // Check for success
        if !execOutputStr.contains("SUCCESS") {
            throw StreamingError.installationFailed(execOutputStr)
        }
        
        print("Miniserve installed successfully")
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
