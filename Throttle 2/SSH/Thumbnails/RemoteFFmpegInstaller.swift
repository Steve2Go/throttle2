import Foundation

/// Utility for ensuring ffmpeg is available on a remote server via SSH.
struct RemoteFFmpegInstaller {
    /// Checks for ffmpeg on the remote server, and if not found, downloads and installs it.
    /// - Returns: The path to the usable ffmpeg binary on the remote server.
    static func ensureFFmpegAvailable(on server: ServerEntity) async throws -> String {
        return try await SSHConnection.withConnection(server: server) { connection in
            try await connection.connect()
            return try await ensureFFmpegAvailable(using: connection)
        }
    }
    
    /// Internal method that works with an existing connection
    static func ensureFFmpegAvailable(using connection: SSHConnection) async throws -> String {
        print("[RemoteFFmpegInstaller] Checking for ffmpeg on remote server...")
        // 1. Check if ffmpeg is already available
        let checkCmd = "command -v ffmpeg || echo 'notfound'"
        let (_, output) = try await connection.executeCommand(checkCmd)
        let ffmpegPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[RemoteFFmpegInstaller] command -v ffmpeg output: \(ffmpegPath)")
        if ffmpegPath != "notfound" && !ffmpegPath.isEmpty {
            print("[RemoteFFmpegInstaller] ffmpeg found at \(ffmpegPath)")
            return ffmpegPath
        }

        // 2. Detect OS and arch
        let (_, osName) = try await connection.executeCommand("uname -s")
        let (_, archName) = try await connection.executeCommand("uname -m")
        let os = osName.trimmingCharacters(in: .whitespacesAndNewlines)
        let arch = archName.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[RemoteFFmpegInstaller] Detected OS: \(os), Arch: \(arch)")  

        // 3. Determine download URL and install path
        var ffmpegURL: String = ""
        var installPath: String = "~/bin/ffmpeg"
        var downloadCmd: String = ""
        if os == "Linux" && arch == "x86_64" {
            ffmpegURL = "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
            installPath = "~/bin/ffmpeg"
            downloadCmd = "mkdir -p ~/bin && cd /tmp && wget -O ffmpeg.tar.xz \"$URL\" && tar -xf ffmpeg.tar.xz && cp ffmpeg-*-static/ffmpeg ~/bin/ && chmod +x ~/bin/ffmpeg"
        } else if os == "Linux" && (arch == "armv6l" || arch == "armv7l") {
            // Raspberry Pi armhf support
            ffmpegURL = "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-armhf-static.tar.xz"
            installPath = "~/bin/ffmpeg"
            downloadCmd = "mkdir -p ~/bin && cd /tmp && wget -O ffmpeg.tar.xz \"$URL\" && tar -xf ffmpeg.tar.xz && cp ffmpeg-*-static/ffmpeg ~/bin/ && chmod +x ~/bin/ffmpeg"
        } else if os == "Darwin" && arch == "arm64" {
            ffmpegURL = "https://www.osxexperts.net/ffmpeg6arm.zip"
            installPath = "~/bin/ffmpeg"
            downloadCmd = "mkdir -p ~/bin && cd /tmp && wget -O ffmpeg.zip \"$URL\" && unzip -o ffmpeg.zip && mv ffmpeg ~/bin/ && chmod +x ~/bin/ffmpeg"
        } else if os == "Darwin" && arch == "x86_64" {
            ffmpegURL = "https://evermeet.cx/ffmpeg/getrelease/zip"
            installPath = "~/bin/ffmpeg"
            downloadCmd = "mkdir -p ~/bin && cd /tmp && wget -O ffmpeg.zip \"$URL\" && unzip -o ffmpeg.zip && mv ffmpeg ~/bin/ && chmod +x ~/bin/ffmpeg"
        } else if os.contains("MINGW") || os.contains("MSYS") || os.contains("CYGWIN") || os.lowercased().contains("windows") {
            // Windows (OpenSSH, Git Bash, or Cygwin/MSYS)
            ffmpegURL = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl-shared.zip"
            installPath = "~/bin/ffmpeg-master-latest-win64-gpl-shared/bin/ffmpeg.exe"
            // Use PowerShell to extract zip in ~/bin
            downloadCmd = "mkdir -p ~/bin; cd ~/bin; wget -O ffmpeg.zip \"$URL\"; powershell -Command \"Expand-Archive -Path ffmpeg.zip -DestinationPath .\";"
        } else {
            print("[RemoteFFmpegInstaller] Unsupported OS/arch: \(os) \(arch)")
            throw NSError(domain: "RemoteFFmpegInstaller", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported OS/arch: \(os) \(arch)"])
        }

        print("[RemoteFFmpegInstaller] Download URL: \(ffmpegURL)")
        print("[RemoteFFmpegInstaller] Download/install command: \(downloadCmd)")

        // 4. Download and install ffmpeg
        let installScript = "URL=\"\(ffmpegURL)\"; \(downloadCmd)"
        print("[RemoteFFmpegInstaller] Running install script: \(installScript)")
        let (status, installOutput) = try await connection.executeCommand(installScript)
        print("[RemoteFFmpegInstaller] Install script status: \(status)")
        print("[RemoteFFmpegInstaller] Install script output: \(installOutput)")
        if status != 0 {
            print("[RemoteFFmpegInstaller] Failed to install ffmpeg: \(installOutput)")
            throw NSError(domain: "RemoteFFmpegInstaller", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to install ffmpeg: \(installOutput)"])
        }

        // 5. Verify installation
        let verifyCmd: String
        if os.contains("MINGW") || os.contains("MSYS") || os.contains("CYGWIN") || os.lowercased().contains("windows") {
            verifyCmd = "~/bin/ffmpeg-master-latest-win64-gpl-shared/bin/ffmpeg.exe -version || echo 'notfound'"
        } else {
            verifyCmd = "~/bin/ffmpeg -version || echo 'notfound'"
        }
        print("[RemoteFFmpegInstaller] Verifying install with: \(verifyCmd)")
        let (verifyStatus, verifyOutput) = try await connection.executeCommand(verifyCmd)
        print("[RemoteFFmpegInstaller] Verify status: \(verifyStatus)")
        print("[RemoteFFmpegInstaller] Verify output: \(verifyOutput)")
        if verifyOutput.contains("notfound") {
            print("[RemoteFFmpegInstaller] ffmpeg install verification failed")
            throw NSError(domain: "RemoteFFmpegInstaller", code: -2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg install verification failed"])
        }
        print("[RemoteFFmpegInstaller] ffmpeg installed successfully at \(installPath)")
        return installPath
    }
    } // End of withConnection block 
