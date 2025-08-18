// Helper function to detect Apple Silicon Macs
// This should be added to a utility file or extension

import Foundation
import SwiftUI

extension ProcessInfo {
    /// Returns true if running on an Apple Silicon Mac
    /// Result is cached in AppStorage to avoid repeated system calls
    static var isAppleSilicon: Bool {
        @AppStorage("isAppleSilicon") var cachedResult: Bool?
        
        // Return cached result if available
        if let cached = cachedResult {
            return cached
        }
        
        #if os(macOS)
        // Check CPU brand string for Apple Silicon
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        
        var cpuBrand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &cpuBrand, &size, nil, 0)
        
        let cpuString = String(cString: cpuBrand)
        let result = cpuString.contains("Apple")
        
        // Cache the result
        cachedResult = result
        return result
        #else
        // Cache false result for non-macOS
        cachedResult = false
        return false
        #endif
    }
}
