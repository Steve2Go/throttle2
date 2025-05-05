//
//  User.swift
//  Throttle 2
//
//  Created by Stephen Grigg on 3/5/2025.
//
//
//#if os(macOS)
//import Cocoa
//
//// Step 1: Typealias UIImage to NSImage
//typealias UIImage = NSImage
//
//// Step 2: You might want to add these APIs that UIImage has but NSImage doesn't.
//extension NSImage {
//    var cgImage: CGImage? {
//        var proposedRect = CGRect(origin: .zero, size: size)
//
//        return cgImage(forProposedRect: &proposedRect,
//                       context: nil,
//                       hints: nil)
//    }
//
//    convenience init?(named name: String) {
//        self.init(named: Name(name))
//    }
//}
//
//// Step 3: Profit - you can now make your model code that uses UIImage cross-platform!
//struct User {
//    let name: String
//    let profileImage: UIImage
//}
//#endif
