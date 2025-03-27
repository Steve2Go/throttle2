////
////  Keychain.swift
////  Throttle 2
////
////  Created by Stephen Grigg on 17/2/2025.
////
//
//import KeychainAccess
//
//import SwiftUI
//import KeychainAccess
//
//@propertyWrapper
//struct KeychainStorage: DynamicProperty {
//    // MARK: - Properties
//    let keychainManager = Keychain()
//    let key: String
//    var wrappedValue: String {
//        didSet {
//            keychainManager[key] = wrappedValue
//        }
//    }
//    // MARK: - Init
//    init(wrappedValue: String = "", _ key: String) {
//        self.key = key
//        let initialValue = (keychainManager[key] ?? wrappedValue)
//        self.wrappedValue = initialValue
//    }
//}
//
//
////usage:
//// @KeychainStorage("password") var password



import SwiftUI
import KeychainAccess

@propertyWrapper
struct KeychainStorage: DynamicProperty {
    let keychainManager: Keychain
    let key: String
    var wrappedValue: String {
        didSet {
            keychainManager[key] = wrappedValue
        }
    }
    
    init(wrappedValue: String = "", _ key: String) {
        self.key = key
        // Initialize the Keychain with the shared access group.
        keychainManager = Keychain(service: "srgim.throttle2", accessGroup: "group.com.srgim.Throttle-2")
            .synchronizable(true)
        let initialValue = keychainManager[key] ?? wrappedValue
        self.wrappedValue = initialValue
    }
}
