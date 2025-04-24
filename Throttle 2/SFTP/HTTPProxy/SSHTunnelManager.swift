import Foundation
import Citadel
import NIO
import NIOSSH
import KeychainAccess

enum SSHTunnelError: Error {
    case missingCredentials
    case connectionFailed(Error)
    case tunnelEstablishmentFailed(Error)
    case portForwardingFailed(Error)
    case localProxyFailed(Error)
    case reconnectFailed(Error)
    case invalidServerConfiguration
    case tunnelAlreadyConnected
    case tunnelNotConnected
}

/// Manages SSH tunnels for port forwarding
class TunnelManagerHolder {
    static let shared = TunnelManagerHolder()
    private var activeTunnels: [String: SSHTunnelManager] = [:]
    private let tunnelLock = NSLock()

    private init() {}
    
    /// Store a tunnel with a custom identifier
    func storeTunnel(_ tunnel: SSHTunnelManager, withIdentifier identifier: String) {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        activeTunnels[identifier] = tunnel
    }
    
    /// Get a tunnel by its identifier
    func getTunnel(withIdentifier identifier: String) -> SSHTunnelManager? {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        return activeTunnels[identifier]
    }
    
    /// Remove a tunnel by its identifier
    func removeTunnel(withIdentifier identifier: String) {
        tunnelLock.lock()
        let tunnel = activeTunnels[identifier]
        tunnelLock.unlock()
        
        if let tunnel = tunnel {
            tunnel.stop()
            
            tunnelLock.lock()
            activeTunnels.removeValue(forKey: identifier)
            tunnelLock.unlock()
        }
    }
    
    /// Tear down all tunnels
    func tearDownAllTunnels() {
        print("TunnelManagerHolder: Tearing down all tunnels")
        
        tunnelLock.lock()
        let tunnels = activeTunnels.values
        activeTunnels.removeAll()
        tunnelLock.unlock()
        
        for tunnel in tunnels {
            tunnel.stop()
        }
        
        print("TunnelManagerHolder: All tunnels have been torn down")
    }
}

/// A simple class that manages an SSH tunnel for port forwarding
class SSHTunnelManager {
    // SSH client connection
    private var client: SSHClient?
    
    // Server channel that listens on local port
    private var serverChannel: Channel?
    
    // Configuration
    var localPort: Int
    private let remoteHost: String
    private let remotePort: Int
    private let server: ServerEntity
    
    // Other state
    private var isStarted = false
    private let tunnelLock = NSLock()
    private var activeConnections = [ObjectIdentifier: Channel]()
    private let connectionLock = NSLock()
    
    /// Initialize the tunnel manager
    /// - Parameters:
    ///   - server: Server configuration entity
    ///   - localPort: Local port to listen on
    ///   - remoteHost: Remote host to connect to (as seen from the SSH server)
    ///   - remotePort: Remote port to connect to
    init(server: ServerEntity, localPort: Int, remoteHost: String, remotePort: Int) throws {
        print("SSHTunnelManager: Initializing tunnel")
        
        // Validate server configuration
        guard let sftpHost = server.sftpHost,
              server.sftpPort != 0,
              let sftpUser = server.sftpUser,
              !sftpHost.isEmpty,
              !sftpUser.isEmpty else {
            throw SSHTunnelError.invalidServerConfiguration
        }
        
        self.server = server
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
    
    deinit {
        print("SSHTunnelManager: Deinitializing")
        stop()
    }
    
    /// Start the SSH tunnel
    func start() async throws {
        tunnelLock.lock()
        
        // Check if the tunnel is already running
        guard !isStarted else {
            tunnelLock.unlock()
            print("Tunnel already started")
            throw SSHTunnelError.tunnelAlreadyConnected
        }
        
        // Mark as started and unlock to avoid deadlocks in subsequent operations
        isStarted = true
        tunnelLock.unlock()
        
        do {
            // 1. Establish SSH connection
            try await connectSSH()
            
            // 2. Setup local listening server
            try await setupLocalServer()
            
            print("SSH Tunnel established: localhost:\(localPort) -> \(remoteHost):\(remotePort)")
        } catch let error as SSHTunnelError {
            // Propagate specific SSH tunnel errors
            tunnelLock.lock()
            isStarted = false
            tunnelLock.unlock()
            
            stop()
            throw error
        } catch {
            // Wrap other errors as connection failures
            tunnelLock.lock()
            isStarted = false
            tunnelLock.unlock()
            
            stop()
            throw SSHTunnelError.connectionFailed(error)
        }
    }
    
    /// Connect to the SSH server
    private func connectSSH() async throws {
        // Get credentials from keychain
        let keychain = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
        guard let password = keychain["sftpPassword" + (server.name ?? "")] else {
            throw SSHTunnelError.missingCredentials
        }
        
        do {
            // Create SSH connection with password authentication
            client = try await SSHClient.connect(
                host: server.sftpHost!,
                port: Int(server.sftpPort),
                authenticationMethod: .passwordBased(username: server.sftpUser!, password: password),
                hostKeyValidator: .acceptAnything(),
                reconnect: .always
            )
            
            print("SSH connection established to \(server.sftpHost!):\(server.sftpPort)")
        } catch let error as NIOSSHError {
            print("SSH connection failed: \(error)")
            throw SSHTunnelError.connectionFailed(error)
        } catch let error as ChannelError where error == ChannelError.connectTimeout(.seconds(30)) {
            print("SSH connection timed out: \(error)")
            throw SSHTunnelError.connectionFailed(error)
        } catch {
            print("SSH connection failed with unexpected error: \(error)")
            throw SSHTunnelError.connectionFailed(error)
        }
    }
    
    /// Create a local server that listens for connections and forwards them through the SSH tunnel
    private func setupLocalServer() async throws {
        guard let client = client else {
            throw SSHTunnelError.tunnelNotConnected
        }
        
        do {
            // Create a server bootstrap
            let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    guard let self = self else {
                        return channel.eventLoop.makeFailedFuture(SSHTunnelError.tunnelNotConnected)
                    }
                    
                    // Track this connection
                    self.addActiveConnection(channel)
                    
                    // When this channel closes, remove it from tracking
                    channel.closeFuture.whenComplete { [weak self] _ in
                        self?.removeActiveConnection(channel)
                    }
                    
                    // Create a task to handle this connection through the SSH tunnel
                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    
                    // Start an async task to handle the tunnel creation
                    Task {
                        do {
                            // Set up a socket address to use for origin information
                            let originAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                            
                            // Configure the DirectTCPIP settings (this is what creates the tunnel)
                            let directTCPIPSettings = NIOSSH.SSHChannelType.DirectTCPIP(
                                targetHost: self.remoteHost,
                                targetPort: self.remotePort,
                                originatorAddress: originAddress
                            )
                            
                            // Create a tunnel channel through the SSH connection
                            let sshChannel = try await client.createDirectTCPIPChannel(
                                using: directTCPIPSettings
                            ) { sshChannel in
                                // No additional handlers needed, the channel automatically does the right thing
                                return sshChannel.eventLoop.makeSucceededVoidFuture()
                            }
                            
                            // Start forwarding data between the local connection and the SSH tunnel
                            try await self.setupBidirectionalRelay(localChannel: channel, sshChannel: sshChannel)
                            
                            promise.succeed(())
                        } catch {
                            print("Failed to establish SSH tunnel connection: \(error)")
                            try? await channel.close()
                            
                            // Map the error to our specific error type
                            if error is NIOSSHError {
                                promise.fail(SSHTunnelError.portForwardingFailed(error))
                            } else if error is ChannelError {
                                promise.fail(SSHTunnelError.localProxyFailed(error))
                            } else {
                                promise.fail(SSHTunnelError.tunnelEstablishmentFailed(error))
                            }
                        }
                    }
                    
                    return promise.futureResult
                }
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            
            // Start the local server
            serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
            print("Local server listening on 127.0.0.1:\(localPort)")
        } catch {
            throw SSHTunnelError.localProxyFailed(error)
        }
    }
    
    /// Set up relaying between the local connection and the SSH tunnel
    private func setupBidirectionalRelay(localChannel: Channel, sshChannel: Channel) async throws {
        do {
            // Create a handler for local to SSH direction
            let localToSSH = LocalToSSHRelayHandler(targetChannel: sshChannel)
            let sshToLocal = SSHToLocalRelayHandler(targetChannel: localChannel)
            
            // Add the handlers to their respective channels
            try await localChannel.pipeline.addHandler(localToSSH).get()
            try await sshChannel.pipeline.addHandler(sshToLocal).get()
        } catch {
            // If we can't set up the relay, throw an appropriate error
            print("Failed to set up bidirectional relay: \(error)")
            throw SSHTunnelError.tunnelEstablishmentFailed(error)
        }
    }
    
    // Simple handlers to relay data between channels
    private class LocalToSSHRelayHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        
        private let targetChannel: Channel
        
        init(targetChannel: Channel) {
            self.targetChannel = targetChannel
        }
        
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = self.unwrapInboundIn(data)
            targetChannel.writeAndFlush(buffer, promise: nil)
        }
    }
    
    private class SSHToLocalRelayHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        
        private let targetChannel: Channel
        
        init(targetChannel: Channel) {
            self.targetChannel = targetChannel
        }
        
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = self.unwrapInboundIn(data)
            targetChannel.writeAndFlush(buffer, promise: nil)
        }
    }
    
    /// Add a channel to the active connections tracking
    private func addActiveConnection(_ channel: Channel) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        activeConnections[ObjectIdentifier(channel)] = channel
    }
    
    /// Remove a channel from the active connections tracking
    private func removeActiveConnection(_ channel: Channel) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        activeConnections.removeValue(forKey: ObjectIdentifier(channel))
    }
    
    /// Stop the SSH tunnel
    func stop() {
        tunnelLock.lock()
        isStarted = false
        tunnelLock.unlock()
        
        print("SSHTunnelManager: Stopping tunnel")
        
        // Close all active connections
        connectionLock.lock()
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        connectionLock.unlock()
        
        for connection in connections {
            connection.close(promise: nil)
        }
        
        // Close the local server
        if let serverChannel = serverChannel {
            serverChannel.close(promise: nil)
            self.serverChannel = nil
        }
        
        // Close the SSH client
        if let client = client {
            Task {
                try? await client.close()
            }
            self.client = nil
        }
        
        print("SSHTunnelManager: Tunnel stopped")
    }
}
