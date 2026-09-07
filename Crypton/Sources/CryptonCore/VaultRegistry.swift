import Foundation

/// Persists the list of known vaults to Application Support.
///
/// This file holds no secrets — only paths, names, and algorithm choices — so
/// its disclosure does not compromise vault contents.
public final class VaultRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.crypton.registry")
    private let storeURL: URL

    public init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Crypton", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("vaults.json")
        }
    }

    public func load() -> [Vault] {
        queue.sync {
            guard let data = try? Data(contentsOf: storeURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([Vault].self, from: data)) ?? []
        }
    }

    /// Writes atomically so a crash mid-save cannot corrupt the registry.
    public func save(_ vaults: [Vault]) throws {
        try queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(vaults)
            try data.write(to: storeURL, options: .atomic)
        }
    }

    public func add(_ vault: Vault) throws {
        var all = load()
        all.append(vault)
        try save(all)
    }

    public func remove(id: UUID) throws {
        try save(load().filter { $0.id != id })
    }
}
