import Foundation
import Citadel
import NIOCore
import NIOPosix
import KeychainAccess
import mft
import NIOEmbedded
import NIOSSH

enum SSHTunnelError: Error {
    case missingCredentials
    case connectionFailed(Error)
    case portForwardingFailed(Error)
    case localProxyFailed(Error)
    case reconnectFailed(Error)
    case invalidServerConfiguration
    case tunnelAlreadyConnected
    case tunnelNotConnected
}

class TunnelManagerHolder {
    static let shared = TunnelManagerHolder()
    
    // Use a custom identifier for each tunnel instead of server name
    var activeTunnels: [String: SSHTunnelManager] = [:]
    
    private init() {}
    
    // Store a tunnel with a custom identifier
    func storeTunnel(_ tunnel: SSHTunnelManager, withIdentifier identifier: String) {
        activeTunnels[identifier] = tunnel
    }
    
    
    // Get a tunnel by its identifier
    func getTunnel(withIdentifier identifier: String) -> SSHTunnelManager? {
        return activeTunnels[identifier]
    }
    
    // Remove a tunnel by its identifier
    func removeTunnel(withIdentifier identifier: String) {
        if let tunnel = activeTunnels[identifier] {
            tunnel.stop()
            activeTunnels.removeValue(forKey: identifier)
        }
    }
    func ensureTunnelHealth(withIdentifier identifier: String) async throws {
            if let tunnel = activeTunnels[identifier] {
                try await tunnel.recreateIfNeeded()
            }
        }
        
        // Method to ensure all tunnels are healthy
        func ensureAllTunnelsHealth() async {
            for (identifier, tunnel) in activeTunnels {
                do {
                    try await tunnel.recreateIfNeeded()
                } catch {
                    print("TunnelManagerHolder: Failed to recreate tunnel with identifier \(identifier): \(error)")
                }
            }
        }
    
    
    
    // Method to tear down all tunnels
    func tearDownAllTunnels() {
        print("TunnelManagerHolder: Tearing down all tunnels")
        
        for (identifier, tunnel) in activeTunnels {
            print("TunnelManagerHolder: Stopping tunnel with identifier: \(identifier)")
            tunnel.stop()
        }
        
        activeTunnels.removeAll()
        print("TunnelManagerHolder: All tunnels have been torn down")
    }
}

class SSHTunnelManager {
    private var client: SSHClient?
    private let group: MultiThreadedEventLoopGroup
    private var localPort: Int
    private var remoteHost: String
    private var remotePort: Int
    private var server: ServerEntity
    private var isConnected: Bool = false
    private var localChannel: Channel?
    private var healthCheckTimer: Timer?
    private var healthCheckTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Error>?

    init(server: ServerEntity, localPort: Int, remoteHost: String, remotePort: Int) throws {
        print("SSHTunnelManager: Initializing tunnel")
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.server = server
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort

        guard server.sftpHost != nil,
              server.sftpPort != 0,
              server.sftpUser != nil else {
            throw SSHTunnelError.invalidServerConfiguration
        }
    }

    deinit {
        print("SSHTunnelManager: Deinitializing")
        
        // Cancel any ongoing tasks
        connectionTask?.cancel()
        connectionTask = nil
        
        // Clean up channels and connections
        stop()
        
        // Shutdown the event loop group
        try? group.syncShutdownGracefully()
    }

    func start() async throws {
        print("SSHTunnelManager: Starting tunnel")
        
        // Cancel any existing task first
        connectionTask?.cancel()
        
        // Create a new task for the connection
        connectionTask = Task { [weak self] in
            guard let self = self else {
                throw SSHTunnelError.connectionFailed(NSError(domain: "SSHTunnelManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self was deallocated"]))
            }
            
            try await self.connect()
            try await self.startBasicProxy()
            
            // Keep this task alive until cancelled to prevent premature deallocation
            try await withTaskCancellationHandler {
                // Wait indefinitely until task is cancelled
                try await Task.sleep(nanoseconds: UInt64.max)
            } onCancel: {
                // Handle clean shutdown when task is cancelled
                print("SSHTunnelManager: Connection task cancelled")
            }
        }
        
        // Wait for the connection to be established
        try await connectionTask?.value
    }

    private func connect() async throws {
        guard let password = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")["sftpPassword" + (server.name ?? "")] else {
            throw SSHTunnelError.missingCredentials
        }

        client = try await SSHClient.connect(
            host: server.sftpHost!,
            port: Int(server.sftpPort),
            authenticationMethod: .passwordBased(username: server.sftpUser!, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .always
        )
        isConnected = true
        print("SSH Tunnel connected to \(server.sftpHost!):\(server.sftpPort)")
    }

    private func startBasicProxy() async throws {
        guard let client = client else {
            throw SSHTunnelError.tunnelNotConnected
        }
        
        // Create a shared context for the tunnels
        let tunnelContext = BasicTunnelContext(
            sshClient: client,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
        
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let handler = BasicTunnelHandler(context: tunnelContext)
                return channel.pipeline.addHandler(handler)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        self.localChannel = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        print("Local HTTP proxy listening on port \(localPort)")
    }

    func isHealthy() -> Bool {
        // Basic check if we have a client and active local channel
        guard let client = client,
              let localChannel = localChannel,
              isConnected == true else {
            return false
        }
        
        // Check if the local channel is still active
        if !localChannel.isActive {
            return false
        }
        
        return true
    }

    func recreateIfNeeded() async throws {
        if !isHealthy() {
            print("SSHTunnelManager: Tunnel is unhealthy, recreating...")
            // Stop the existing tunnel first
            stop()
            
            
            // Wait a moment before reconnecting
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            
            // Recreate the tunnel
            try await start()
            print("SSHTunnelManager: Tunnel has been recreated")
        }
    }

    // Add method to periodically check health
    func startHealthChecks(interval: TimeInterval = 60.0) {
        // Cancel any existing health check task first
        stopHealthChecks()
        
        // Create a task for health checks that won't cause memory leaks
        healthCheckTask = Task { [weak self] in
            // Continue health checks until task is cancelled
            while !Task.isCancelled {
                guard let self = self else { break }
                
                do {
                    try await self.recreateIfNeeded()
                    
                    // Wait for the specified interval before checking again
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    if !Task.isCancelled {
                        print("SSHTunnelManager: Health check error: \(error)")
                        // Add a shorter delay if an error occurs
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                    }
                }
            }
        }
    }
    // Method to stop health checks
    func stopHealthChecks() {
        // Cancel the health check task
        healthCheckTask?.cancel()
        healthCheckTask = nil
        
        // Also cleanup timer if it exists (for legacy code)
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }


    func stop() {
        print("SSHTunnelManager: Stopping tunnel")
        isConnected = false
        
        // Cancel the connection task
        connectionTask?.cancel()
        connectionTask = nil
        
        // Ensure we close the local channel on the correct event loop
        if let localChannel = localChannel {
            localChannel.eventLoop.execute {
                localChannel.close(promise: nil)
            }
            self.localChannel = nil
        }
        
        // Close the SSH client
        if let client = client {
            Task {
                try? await client.close()
                self.client = nil
                print("SSH Tunnel stopped")
            }
        }
    }
}

// A shared context to hold tunnel information
class BasicTunnelContext {
    let sshClient: SSHClient
    let remoteHost: String
    let remotePort: Int
    
    init(sshClient: SSHClient, remoteHost: String, remotePort: Int) {
        self.sshClient = sshClient
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

// Extremely basic tunnel handler
class BasicTunnelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let context: BasicTunnelContext
    private var remoteChannel: Channel?
    private var pendingData: [ByteBuffer] = []
    private var remoteConnected = false
    private var connectionTask: Task<Void, Error>?
    
    init(context: BasicTunnelContext) {
        self.context = context
    }
    
    deinit {
        print("BasicTunnelHandler: Deinitializing")
        connectionTask?.cancel()
        remoteChannel?.close(promise: nil)
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("BasicTunnel: Local connection established")
        
        // Store weak references to avoid cycles
        weak var weakSelf = self
        weak var weakLocalChannel = context.channel
        
        // Cancel any existing task
        connectionTask?.cancel()
        
        // Create a new connection task
        connectionTask = Task {
            guard let self = weakSelf, let localChannel = weakLocalChannel else {
                throw NSError(domain: "BasicTunnelHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Handler or channel was deallocated"])
            }
            
            do {
                // Create the tunnel to the remote host
                let originAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                
                let settings = SSHChannelType.DirectTCPIP(
                    targetHost: self.context.remoteHost,
                    targetPort: self.context.remotePort,
                    originatorAddress: originAddress
                )
                
                // Use a simpler approach with the SSH channel
                let remoteChannel = try await self.context.sshClient.createDirectTCPIPChannel(
                    using: settings
                ) { channel in
                    // Add a basic handler that doesn't rely on strong context references
                    let handler = BasicOutboundHandler()
                    return channel.pipeline.addHandler(handler)
                }
                
                // Check if still alive before proceeding
                guard !Task.isCancelled, let self = weakSelf, let localChannel = weakLocalChannel else {
                    remoteChannel.close(promise: nil)
                    throw NSError(domain: "BasicTunnelHandler", code: -2, userInfo: [NSLocalizedDescriptionKey: "Task cancelled or references lost"])
                }
                
                // Store the remote channel
                self.remoteChannel = remoteChannel
                
                // Set up data relay
                try await self.setupDataRelay(localChannel: localChannel, remoteChannel: remoteChannel)
                
                print("BasicTunnel: Remote connection established")
                
                // Execute on the correct event loop
                localChannel.eventLoop.execute {
                    guard let self = weakSelf, !Task.isCancelled else { return }
                    
                    self.remoteConnected = true
                    
                    // Forward any pending data
                    for buffer in self.pendingData {
                        remoteChannel.writeAndFlush(buffer, promise: nil)
                    }
                    self.pendingData.removeAll()
                }
            } catch {
                print("BasicTunnel: Failed to establish remote connection: \(error)")
                weakLocalChannel?.close(promise: nil)
            }
        }
    }
    
    private func setupDataRelay(localChannel: Channel, remoteChannel: Channel) async throws {
        // Create a very simple promise to verify success
        let promise = localChannel.eventLoop.makePromise(of: Void.self)
        
        // Execute on the remote channel's event loop
        remoteChannel.eventLoop.execute {
            // Add a handler to relay data back to the local channel
            remoteChannel.pipeline.addHandler(
                BasicRelayHandler(targetChannel: localChannel)
            ).whenComplete { result in
                switch result {
                case .success:
                    promise.succeed(())
                case .failure(let error):
                    promise.fail(error)
                }
            }
        }
        
        // Wait for the handler to be added
        try await promise.futureResult.get()
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        
        if let remoteChannel = remoteChannel, remoteConnected {
            // Forward data to the remote channel
            remoteChannel.writeAndFlush(buffer, promise: nil)
        } else {
            // Buffer data until remote connection is established
            pendingData.append(buffer)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("BasicTunnel: Local connection closed")
        
        // Cancel the task to avoid dangling references
        connectionTask?.cancel()
        connectionTask = nil
        
        // Close the remote channel on its own event loop
        if let remoteChannel = remoteChannel {
            remoteChannel.eventLoop.execute {
                remoteChannel.close(promise: nil)
            }
            self.remoteChannel = nil
        }
        
        // Clear any pending data
        pendingData.removeAll()
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("BasicTunnel: Error caught: \(error)")
        
        // Clean up resources
        connectionTask?.cancel()
        connectionTask = nil
        
        if let remoteChannel = remoteChannel {
            remoteChannel.close(promise: nil)
            self.remoteChannel = nil
        }
        
        // Close the context
        context.close(promise: nil)
    }
}

// Handler for SSH channel outbound data
class BasicOutboundHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    func channelActive(context: ChannelHandlerContext) {
        print("BasicOutbound: Channel active")
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        //print("BasicOutbound: Received data from remote")
        
        // Just pass through the data
        context.fireChannelRead(data)
    }
}

// Basic relay handler that just forwards data between channels
class BasicRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    // Use weak reference to avoid circular dependencies
    private weak var targetChannel: Channel?
    
    init(targetChannel: Channel) {
        self.targetChannel = targetChannel
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Only forward if target channel still exists
        if let targetChannel = targetChannel {
            targetChannel.writeAndFlush(data, promise: nil)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("BasicRelay: Channel inactive")
        targetChannel?.close(promise: nil)
    }
}


//// Example usage for different tunnel purposes
//let transmissionTunnel = try SSHTunnelManager(server: server, localPort: 4000, remoteHost: "localhost", remotePort: 9091)
//try await transmissionTunnel.start()
//TunnelManagerHolder.shared.storeTunnel(transmissionTunnel, withIdentifier: "transmission-rpc")
//
//// Another tunnel for a different service on the same server
//let webTunnel = try SSHTunnelManager(server: server, localPort: 4001, remoteHost: "localhost", remotePort: 80)
//try await webTunnel.start()
//TunnelManagerHolder.shared.storeTunnel(webTunnel, withIdentifier: "web-server")
//
//// And later when you need to access them
//if let transmissionTunnel = TunnelManagerHolder.shared.getTunnel(withIdentifier: "transmission-rpc") {
//    // Use the transmission tunnel
//}
//
//// To stop a specific tunnel
//TunnelManagerHolder.shared.removeTunnel(withIdentifier: "web-server")
//
//// To stop all tunnels
//TunnelManagerHolder.shared.tearDownAllTunnels()
