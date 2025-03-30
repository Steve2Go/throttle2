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
    private var remotePort: Int
    private var server: ServerEntity
    private var isConnected: Bool = false
    private var localChannel: Channel?

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
        stop()
        try? group.syncShutdownGracefully()
    }

    func start() async throws {
        print("SSHTunnelManager: Starting tunnel")
        try await connect()
        try await startBasicProxy()
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
            reconnect: .never
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

    func stop() {
        print("SSHTunnelManager: Stopping tunnel")
        isConnected = false
        
        if let localChannel = localChannel {
            localChannel.close(promise: nil)
            self.localChannel = nil
        }
        
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
    
    init(context: BasicTunnelContext) {
        self.context = context
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("BasicTunnel: Local connection established")
        
        let localChannel = context.channel
        
        Task {
            do {
                // Create the tunnel to the remote host
                let originAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                
                let settings = SSHChannelType.DirectTCPIP(
                    targetHost: self.context.remoteHost,
                    targetPort: self.context.remotePort,
                    originatorAddress: originAddress
                )
                
                // Use a much simpler approach with the SSH channel
                let remoteChannel = try await self.context.sshClient.createDirectTCPIPChannel(
                    using: settings
                ) { channel in
                    // Only add a basic handler that doesn't rely on context
                    let handler = BasicOutboundHandler()
                    return channel.pipeline.addHandler(handler)
                }
                
                // Store the remote channel
                self.remoteChannel = remoteChannel
                
                // Set up a very basic byte relay
                try await setupDataRelay(localChannel: localChannel, remoteChannel: remoteChannel)
                
                print("BasicTunnel: Remote connection established")
                
                // At this point, the channels are connected
                localChannel.eventLoop.execute {
                    self.remoteConnected = true
                    
                    // Forward any pending data
                    for buffer in self.pendingData {
                        remoteChannel.writeAndFlush(buffer, promise: nil)
                    }
                    self.pendingData.removeAll()
                }
            } catch {
                print("BasicTunnel: Failed to establish remote connection: \(error)")
                localChannel.close(promise: nil)
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
        remoteChannel?.close(promise: nil)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("BasicTunnel: Error caught: \(error)")
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
    
    private let targetChannel: Channel
    
    init(targetChannel: Channel) {
        self.targetChannel = targetChannel
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Forward data to the target channel
        // We don't transform the data, just pass it through
        targetChannel.writeAndFlush(data, promise: nil)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        print("BasicRelay: Channel inactive")
        targetChannel.close(promise: nil)
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
