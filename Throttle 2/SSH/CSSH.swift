////
////  SSHError.swift
////  Throttle 2
////
////  Created by Stephen Grigg on 26/4/2025.
////
//
//
//import Foundation
//import CSSH
//
////enum SSHError: Error {
////    case initializationFailed
////    case handshakeFailsed
////    case authenticationFailed
////    case connectionFailed
////    case invalidSocket
////}
//
//class SSHSession {
//    private var session: OpaquePointer?
//    private var socket: Int32 = 0
//    
//    init() throws {
//        // Initialize libssh2
//        guard libssh2_init(0) == 0 else {
//            throw SSHError.initializationFailed
//        }
//        
//        // Create session
//    guard let newSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
//        throw SSHError.initializationFailed
//    }
//    }
//    
//    deinit {
//        if let session = session {
//            libssh2_session_free(session)
//        }
//        libssh2_exit()
//    }
//}
