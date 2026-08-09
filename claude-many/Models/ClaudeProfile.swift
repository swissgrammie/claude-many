import Foundation

/// A single Claude Desktop profile: a user-facing label plus the private
/// data directory that holds this instance's login, cookies, config and
/// sessions. Two profiles never share a data directory, so each instance is
/// logged into a different account.
struct ClaudeProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var label: String
    /// Absolute URL of this profile's private data directory. Created lazily
    /// on first start; Claude builds its own layout inside it on first run.
    var dataDirectory: URL

    init(id: UUID = UUID(), label: String, dataDirectory: URL) {
        self.id = id
        self.label = label
        self.dataDirectory = dataDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case dataDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        let path = try container.decode(String.self, forKey: .dataDirectory)
        dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(dataDirectory.path, forKey: .dataDirectory)
    }
}
