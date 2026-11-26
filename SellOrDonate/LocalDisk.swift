import Foundation
import Security

actor LocalDisk {
    private let test: Bool
    private var revision = 0
    private var accessRevision = 0

    init(test: Bool) { self.test = test }

    private var directory: URL {
        URL.applicationSupportDirectory.appending(path: test ? "SellOrDonateUITest" : "SellOrDonate",
                                                     directoryHint: .isDirectory)
    }

    private var stateFile: URL { directory.appending(path: "work.json") }
    private var accessFile: URL { directory.appending(path: "access.json") }

    func load(reset: Bool) throws -> LocalState? {
        if test && reset && FileManager.default.fileExists(atPath: stateFile.path) {
            try FileManager.default.removeItem(at: stateFile)
        }
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        return try StateArchive.decode(Data(contentsOf: stateFile))
    }

    func save(_ state: LocalState, revision: Int) throws {
        guard revision > self.revision else { return }
        try makeDirectory()
        try StateArchive.encode(state).write(to: stateFile, options: .atomic)
        self.revision = revision
    }

    func readAccess() -> Entitlement? {
        guard !test else { return nil }
        let decoder = JSONDecoder()
        let disk = (try? Data(contentsOf: accessFile)).flatMap { try? decoder.decode(Entitlement.self, from: $0) }
        var result: CFTypeRef?
        var query = accessQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let secure = try? decoder.decode(Entitlement.self, from: data) else {
            return disk
        }
        guard var current = disk else { return secure }
        current.firstOpen = min(current.firstOpen, secure.firstOpen)
        current.proStartedAt = [current.proStartedAt, secure.proStartedAt].compactMap { $0 }.min()
        current.trialClaimedAt = [current.trialClaimedAt, secure.trialClaimedAt].compactMap { $0 }.min()
        current.lastSeen = [current.lastSeen, secure.lastSeen].compactMap { $0 }.max()
        return current
    }

    func saveAccess(_ value: Entitlement, revision: Int) {
        guard !test, revision > accessRevision, let data = try? JSONEncoder().encode(value) else { return }
        accessRevision = revision
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(accessQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = accessQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
        do {
            try makeDirectory()
            try data.write(to: accessFile, options: .atomic)
        } catch {
        }
    }

    func export(_ data: Data, filename: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func readCode(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard let data = try input.read(upToCount: ShareCode.maximumBytes + 1),
              data.count <= ShareCode.maximumBytes,
              let code = String(data: data, encoding: .utf8) else { throw ShareCode.Failure.invalid }
        return code
    }

    private var accessQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.hgsldswk.sellordonate.entitlement",
         kSecAttrAccount as String: "v1"]
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var local = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? local.setResourceValues(values)
    }
}
