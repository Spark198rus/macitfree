import Foundation

/// One item stored in an archive, as reported by the listing backend.
public struct ArchiveEntry: Hashable, Sendable {
    /// Normalised path: no leading `./` or `/`, no trailing `/`, `/`-separated.
    public var path: String
    /// The path exactly as the archive stores it (used to address the entry in helper tools).
    public var rawPath: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var linkTarget: String?
    public var size: UInt64?
    public var compressedSize: UInt64?
    public var modified: Date?
    public var isEncrypted: Bool
    public var crc32: UInt32?
    public var permissions: UInt16?
    public var method: String?

    public init(
        rawPath: String,
        isDirectory: Bool = false,
        isSymlink: Bool = false,
        linkTarget: String? = nil,
        size: UInt64? = nil,
        compressedSize: UInt64? = nil,
        modified: Date? = nil,
        isEncrypted: Bool = false,
        crc32: UInt32? = nil,
        permissions: UInt16? = nil,
        method: String? = nil
    ) {
        self.rawPath = rawPath
        self.path = ArchiveEntry.normalize(rawPath)
        self.isDirectory = isDirectory || rawPath.hasSuffix("/")
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.size = size
        self.compressedSize = compressedSize
        self.modified = modified
        self.isEncrypted = isEncrypted
        self.crc32 = crc32
        self.permissions = permissions
        self.method = method
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The selector passed to extraction tools to address this entry (and, for directories, its subtree).
    public var selector: String {
        var raw = rawPath
        while raw.count > 1 && raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }

    public static func normalize(_ raw: String) -> String {
        var components: [Substring] = []
        for part in raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            components.append(part)
        }
        return components.joined(separator: "/")
    }
}

/// A node of the folder tree built from a flat entry list. Missing intermediate folders are synthesised.
public final class ArchiveNode: Identifiable, Hashable {
    public let path: String
    public let name: String
    public private(set) var entry: ArchiveEntry?
    public private(set) var childNodes: [ArchiveNode] = []
    public weak var parent: ArchiveNode?
    private var childIndex: [String: ArchiveNode] = [:]

    public var id: String { path }
    public var isDirectory: Bool { entry?.isDirectory ?? true }
    /// `nil` for files so SwiftUI outline tables render them as leaves.
    public var children: [ArchiveNode]? { isDirectory ? childNodes : nil }
    /// Whether this node is backed by a real entry (versus a synthesised folder).
    public var isSynthesized: Bool { entry == nil }

    public var size: UInt64 {
        if isDirectory { return childNodes.reduce(0) { $0 + $1.size } }
        return entry?.size ?? 0
    }

    public var compressedSize: UInt64? {
        if isDirectory {
            var total: UInt64 = 0
            for child in childNodes {
                guard let c = child.compressedSize else { return nil }
                total += c
            }
            return total
        }
        return entry?.compressedSize
    }

    public var modified: Date? {
        if let date = entry?.modified { return date }
        return childNodes.compactMap(\.modified).max()
    }

    public var fileCount: Int {
        isDirectory ? childNodes.reduce(0) { $0 + $1.fileCount } : 1
    }

    public var isEncrypted: Bool {
        if let entry, !entry.isDirectory { return entry.isEncrypted }
        return childNodes.contains { $0.isEncrypted }
    }

    init(path: String, name: String, entry: ArchiveEntry?) {
        self.path = path
        self.name = name
        self.entry = entry
    }

    /// All descendants (depth-first), excluding self.
    public var descendants: [ArchiveNode] {
        childNodes.flatMap { [$0] + $0.descendants }
    }

    /// Looks up a descendant by its normalised path.
    public func node(at path: String) -> ArchiveNode? {
        if path.isEmpty { return self }
        var current: ArchiveNode = self
        for part in path.split(separator: "/") {
            guard let next = current.childIndex[String(part)] else { return nil }
            current = next
        }
        return current
    }

    /// Selectors that address this node in the archive. A synthesised folder has no entry of its
    /// own, so it is addressed through its children.
    public var selectors: [String] {
        if let entry { return [entry.selector] }
        return childNodes.flatMap(\.selectors)
    }

    public static func == (lhs: ArchiveNode, rhs: ArchiveNode) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// Builds a tree from a flat listing; the returned root has an empty path.
    public static func tree(from entries: [ArchiveEntry]) -> ArchiveNode {
        let root = ArchiveNode(path: "", name: "", entry: nil)
        for entry in entries where !entry.path.isEmpty {
            let parts = entry.path.split(separator: "/").map(String.init)
            var current = root
            for (i, part) in parts.enumerated() {
                let isLast = i == parts.count - 1
                if let existing = current.childIndex[part] {
                    if isLast && existing.entry == nil { existing.entry = entry }
                    current = existing
                } else {
                    let path = parts[0...i].joined(separator: "/")
                    let node = ArchiveNode(path: path, name: part, entry: isLast ? entry : nil)
                    node.parent = current
                    current.childIndex[part] = node
                    current.childNodes.append(node)
                    current = node
                }
            }
        }
        root.sortRecursively()
        return root
    }

    private func sortRecursively() {
        childNodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        childNodes.forEach { $0.sortRecursively() }
    }

    /// Removes nodes whose ancestor is also present, so a folder and its contents are not processed twice.
    public static func topMost(_ nodes: [ArchiveNode]) -> [ArchiveNode] {
        let paths = Set(nodes.map(\.path))
        return nodes.filter { node in
            var p = node.parent
            while let current = p, !current.path.isEmpty {
                if paths.contains(current.path) { return false }
                p = current.parent
            }
            return true
        }
    }
}
