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
    var remotePort: Int
    private var server: ServerEntity
    private var isConnected: Bool = false
    private var localChannel: Channel?
    private var healthCheckTimer: Timer?
    private var healthCheckTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Error>?

    init(server: ServerEntity, localPort: Int, remoteHost: String, remotePort: Int) throws {
        print("SSHTunnelManager: Initializing tunnel")
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
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
            do {
                    try await withTaskCancellationHandler {
                        try await Task.sleep(nanoseconds: UInt64.max)
                    } onCancel: {
                        Task { [weak self] in
                            self?.stop()
                        }
                    }
                } catch {
                    if error is CancellationError {
                        print("Connection task cancelled normally")
                    } else {
                        throw error
                    }
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
            .serverChannelOption(ChannelOptions.backlog, value: 512)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let handler = BasicTunnelHandler(context: tunnelContext)
                return channel.pipeline.addHandler(handler)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        self.localChannel = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        print("Local HTTP proxy listening on port \(localPort)")
    }


    // Modified stop() method
    func stop() {
        print("SSHTunnelManager: Stopping tunnel")
        if let localChannel = localChannel {
            localChannel.pipeline.handler(type: BasicTunnelHandler.self).whenSuccess { handler in
              //  (handler as? BasicTunnelHandler)?.cancelDownload()
            }
        }
        isConnected = false

        // Cancel the connection task
        connectionTask?.cancel()
        connectionTask = nil

        // Take a snapshot of the channel before clearing
        let channelToClose = localChannel
        localChannel = nil

        // Close the local channel on its own event loop
        if let channel = channelToClose {
            channel.eventLoop.scheduleTask(in: .milliseconds(50)) {
                // Use a promise to ensure the close completes
                let promise = channel.eventLoop.makePromise(of: Void.self)
                channel.close(promise: promise)

                // Log when the close completes
                promise.futureResult.whenComplete { result in
                    switch result {
                    case .success:
                        print("Local channel closed successfully")
                    case .failure(let error):
                        print("Local channel close error: \(error)")
                    }
                }
            }
        }

        // Take a snapshot of the client before clearing
        let clientToClose = client
        client = nil

        // Close the SSH client if it exists
        if let client = clientToClose {
            Task {
                do {
                    try await client.close()
                    print("SSH client closed successfully")
                } catch {
                    print("SSH client close error: \(error)")
                }
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
class BasicRelayHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    // Use weak reference to avoid circular dependencies
    private var targetChannel: Channel?
    private var channelContext: ChannelHandlerContext?
    private var isClosing = false
    private var relayLock = NSLock()
    func channelActive(context: ChannelHandlerContext) {
        self.channelContext = context
        print("BasicRelay: Channel active")
        context.fireChannelActive()
    }

    init(targetChannel: Channel) {
        self.targetChannel = targetChannel
    }
    
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        relayLock.lock()
        defer { relayLock.unlock() }
        
        guard !isClosing,
              let targetChannel = targetChannel,
              targetChannel.isActive else {
            return
        }
        
        let buffer = self.unwrapInboundIn(data)
        targetChannel.write(buffer, promise: nil)
    }
    
    

    func channelReadComplete(context: ChannelHandlerContext) {
        relayLock.lock()
        defer { relayLock.unlock() }
        // Only flush if we're not closing and target channel is active
        guard !isClosing, let targetChannel = targetChannel, targetChannel.isActive else { return }
        do {
            targetChannel.flush()
        }
    }
}

class BasicTunnelHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let context: BasicTunnelContext
    private weak var channelContext: ChannelHandlerContext?
    private var remoteChannel: Channel?
    private var pendingData: [ByteBuffer] = []
    private var remoteConnected = false
    private var connectionTask: Task<Void, Error>?
    private var isShuttingDown = false
    private let tunnelLock = NSLock()
    
    init(context: BasicTunnelContext) {
        self.context = context
    }
    
    deinit {
        print("BasicTunnelHandler: Deinitializing")
        initiateGracefulShutdown()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelEvent, isShuttingDown {
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelActive(context: ChannelHandlerContext) {
        print("BasicTunnel: Local connection established")
        self.channelContext = context
        
        weak var weakSelf = self
        weak var weakLocalChannel = context.channel
        
        connectionTask?.cancel()
        
        connectionTask = Task {
            guard let self = weakSelf, let localChannel = weakLocalChannel else {
                throw NSError(domain: "BasicTunnelHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Handler or channel was deallocated"])
            }
            
            do {
                let originAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                
                let settings = SSHChannelType.DirectTCPIP(
                    targetHost: self.context.remoteHost,
                    targetPort: self.context.remotePort,
                    originatorAddress: originAddress
                )
                
                let remoteChannel = try await self.context.sshClient.createDirectTCPIPChannel(
                    using: settings
                ) { channel in
                    let handler = BasicOutboundHandler()
                    return channel.pipeline.addHandler(handler)
                }
                
                self.remoteChannel = remoteChannel
                
                try await self.setupDataRelay(localChannel: localChannel, remoteChannel: remoteChannel)
                
                print("BasicTunnel: Remote connection established")
                
                // Process pending data on remote channel's event loop
                remoteChannel.eventLoop.execute {
                    self.remoteConnected = true
                    if remoteChannel.isActive {
                        for buffer in self.pendingData {
                            remoteChannel.writeAndFlush(buffer, promise: nil)
                        }
                        self.pendingData.removeAll()
                    } else {
                        print("BasicTunnelHandler: Remote channel is not active. Skipping pending data.")
                    }
                }
            } catch {
                print("BasicTunnel: Failed to establish remote connection: \(error)")
                weakLocalChannel?.close(mode: .all, promise: nil)
            }
        }
    }
    
    private func setupDataRelay(localChannel: Channel, remoteChannel: Channel) async throws {
        let promise = localChannel.eventLoop.makePromise(of: Void.self)
        
        remoteChannel.eventLoop.execute {
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
        
        try await promise.futureResult.get()
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        
        guard !isShuttingDown else { return }
        
        let buffer = unwrapInboundIn(data)
        
        if let remoteChannel = self.remoteChannel,
           remoteChannel.isActive,
           self.remoteConnected {
            remoteChannel.eventLoop.execute {
                remoteChannel.writeAndFlush(buffer, promise: nil)
            }
        } else {
            pendingData.append(buffer)
        }
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        // No need for explicit flush as we're using writeAndFlush
    }
    
    private func initiateGracefulShutdown() {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        
        guard !isShuttingDown else { return }
        isShuttingDown = true
        
        channelContext?.eventLoop.execute {
            self.connectionTask?.cancel()
            self.pendingData.removeAll()
            
            if let remoteChannel = self.remoteChannel {
                remoteChannel.close(promise: nil)
            }
            
            self.channelContext?.close(promise: nil)
            self.channelContext?.pipeline.removeHandler(self, promise: nil)
        }
    }
}
