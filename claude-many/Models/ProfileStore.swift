import Foundation

/// Persists the profile list as a small JSON file. This is the only thing
/// claude-many stores about profiles; all real account data lives in each
/// profile's private data directory and is created by Claude at runtime.
struct ProfileStore: Sendable {
    let fileURL: URL

    /// Returns the stored profiles, or an empty list when no file exists yet.
    func load() throws -> [ClaudeProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ClaudeProfile].self, from: data)
    }

    func save(_ profiles: [ClaudeProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }
}
