import Foundation

/// Generates strong random passwords using the system CSPRNG.
public struct PasswordGenerator: Codable, Equatable, Sendable {
    public var length = 20
    public var includeUppercase = true
    public var includeLowercase = true
    public var includeDigits = true
    public var includeSymbols = true
    /// Leave out look-alike characters such as `l`, `1`, `I`, `O` and `0`.
    public var avoidAmbiguous = true

    public init() {}

    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let digits = Array("0123456789")
    static let symbols = Array("!#$%&*+-=?@^_~.,:;")
    static let ambiguous = Set("lI1O0o")

    public func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    public func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        var classes: [[Character]] = []
        if includeUppercase { classes.append(Self.upper) }
        if includeLowercase { classes.append(Self.lower) }
        if includeDigits { classes.append(Self.digits) }
        if includeSymbols { classes.append(Self.symbols) }
        if classes.isEmpty { classes = [Self.lower] }
        if avoidAmbiguous { classes = classes.map { $0.filter { !Self.ambiguous.contains($0) } } }

        let length = max(length, classes.count, 4)
        // One character from every enabled class, the rest from the union, then shuffle.
        var chars = classes.map { $0.randomElement(using: &rng)! }
        let all = classes.flatMap { $0 }
        while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }

    /// Rough entropy estimate in bits.
    public var entropyBits: Double {
        var pool = 0
        if includeUppercase { pool += Self.upper.count }
        if includeLowercase { pool += Self.lower.count }
        if includeDigits { pool += Self.digits.count }
        if includeSymbols { pool += Self.symbols.count }
        if avoidAmbiguous { pool -= 5 }
        return Double(max(length, 4)) * log2(Double(max(pool, 2)))
    }
}
