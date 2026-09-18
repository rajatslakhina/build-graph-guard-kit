import Foundation

/// Path handling for graph canonicalisation.
///
/// Two branches can describe the same file as `Demo/./Models/Item.swift` and
/// `Demo/Models/Item.swift`. If those compare unequal, every migration produces a
/// diff full of membership churn, and a reviewer stops reading membership diffs —
/// which is precisely where a quietly added file would be.
public enum PathNormalizer {

    /// Joins a prefix and a component, tolerating empty or slash-decorated inputs.
    public static func join(_ prefix: String, _ component: String) -> String {
        let trimmedComponent = component.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return trimmedComponent }
        guard !trimmedComponent.isEmpty else { return prefix }
        if prefix.hasSuffix("/") { return prefix + trimmedComponent }
        return prefix + "/" + trimmedComponent
    }

    /// Collapses `.`, resolves `..` where it can, squeezes repeated separators and
    /// strips a trailing separator.
    ///
    /// A leading `..` that cannot be resolved is *kept*, not dropped. Dropping it
    /// would map `../Secrets/keys.plist` onto `Secrets/keys.plist` and make an
    /// escape out of the project directory look like an ordinary in-tree file.
    public static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var resolved: [String] = []
        // Tracks how many leading `..` we kept, so a later `..` can never pop one
        // of them off and change the meaning of the path.
        var pinnedPrefixCount = 0

        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if resolved.count > pinnedPrefixCount {
                    resolved.removeLast()
                } else if isAbsolute {
                    // `/..` is `/` on every filesystem we care about; drop it.
                    continue
                } else {
                    resolved.append("..")
                    pinnedPrefixCount = SaturatingMath.add(pinnedPrefixCount, 1)
                }
            default:
                resolved.append(String(piece))
            }
        }

        let joined = resolved.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined
    }

    /// Whether a normalised path escapes the project directory.
    public static func escapesProjectDirectory(_ normalizedPath: String) -> Bool {
        normalizedPath.hasPrefix("/") || normalizedPath == ".." || normalizedPath.hasPrefix("../")
    }

    /// Derives a package identity from its URL the way SwiftPM does: the last path
    /// component, minus a `.git` suffix, lowercased.
    public static func packageIdentity(fromURL url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        guard let lastSeparator = trimmed.lastIndex(where: { $0 == "/" || $0 == ":" }) else {
            return trimmed.lowercased()
        }
        let component = String(trimmed[trimmed.index(after: lastSeparator)...])
        return component.isEmpty ? trimmed.lowercased() : component.lowercased()
    }
}
