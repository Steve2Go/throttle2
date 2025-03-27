//#if os(iOS)
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

class SSHConnection {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    
    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
    
    deinit {
        try? disconnect()
    }
    
    func connect() async throws {
        // Create a new event loop group if needed
        if group == nil {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        
        guard let group = group else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create event loop group"])
        }
        
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: PasswordDelegate(username: self.username, password: self.password),
                            serverAuthDelegate: AcceptAllHostKeysDelegate()
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ),
                    ErrorHandler()
                ])
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
        
        self.channel = try await bootstrap.connect(host: host, port: port).get()
    }
    
    func disconnect() throws {
        try channel?.close().wait()
        try group?.syncShutdownGracefully()
        channel = nil
        group = nil
    }
    
    func executeCommand(_ command: String) async throws -> (status: Int32, output: String) {
        // Ensure we're connected
        if channel == nil {
            try await connect()
        }
        
        guard let channel = channel else {
            throw NSError(domain: "SSHConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        let outputPromise = channel.eventLoop.makePromise(of: String.self)
        let exitStatusPromise = channel.eventLoop.makePromise(of: Int.self)
        
        let childChannel = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return childChannel.pipeline.addHandlers([
                    ExecHandler(command: command, outputPromise: outputPromise, exitStatusPromise: exitStatusPromise),
                    ErrorHandler()
                ])
            }
            return promise.futureResult
        }.get()
        
        defer {
            try? childChannel.close().wait()
        }
        
        // Wait for command to complete
        let exitStatus = try await exitStatusPromise.futureResult.get()
        let output = try await outputPromise.futureResult.get()
        
        return (Int32(exitStatus), output)
    }
    
}


private enum SSHError: Error {
    case invalidChannelType
}

private final class PasswordDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String
    
    init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let offer = NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password)))
        nextChallengePromise.succeed(offer)
    }
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("SSH Error: \(error)")
        context.close(promise: nil)
    }
}

private final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    
    private let command: String
    private let outputPromise: EventLoopPromise<String>
    private let exitStatusPromise: EventLoopPromise<Int>
    private var outputBuffer: String
    private var hasExited: Bool = false
    
    init(command: String, outputPromise: EventLoopPromise<String>, exitStatusPromise: EventLoopPromise<Int>) {
        self.command = command
        self.outputPromise = outputPromise
        self.exitStatusPromise = exitStatusPromise
        self.outputBuffer = ""
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest, promise: nil)
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        
        if case let .byteBuffer(buffer) = channelData.data {
            let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
            outputBuffer += str
        }
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus {
            hasExited = true
            exitStatusPromise.succeed(Int(exitStatus.exitStatus))
            outputPromise.succeed(outputBuffer)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        if !hasExited {
            exitStatusPromise.succeed(0)
            outputPromise.succeed(outputBuffer)
        }
    }
}




//#endif
