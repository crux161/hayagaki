import libsumi

// MARK: - Swiftiness for Sumi
extension sumi.vec3: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "vec3(\(self.x), \(self.y), \(self.z))"
    }
}

// MARK: - Operator Bridging
extension sumi.vec3 {
    // Manually implement + using the properties (x, y, z)
    static func + (lhs: sumi.vec3, rhs: sumi.vec3) -> sumi.vec3 {
        // Swift imports C++ constructors as init()
        // We use the properties directly to avoid "missing member" errors
        return sumi.vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    // Manually implement * (scalar)
    static func * (lhs: sumi.vec3, rhs: Float) -> sumi.vec3 {
        return sumi.vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }
    
    // Commutative support: Float * vec3
    static func * (lhs: Float, rhs: sumi.vec3) -> sumi.vec3 {
        return sumi.vec3(rhs.x * lhs, rhs.y * lhs, rhs.z * lhs)
    }
}
