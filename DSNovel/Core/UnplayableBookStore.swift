import Foundation

/// 「无法播放」书籍黑名单：当书籍详情确认没有任何可播放章节时记录，
/// 之后在搜索与发现的结果解码阶段直接过滤，避免用户再次点进空书。
/// 线程安全，可在任意线程读写；最多保留 3000 条，超出后淘汰最早记录。
/// 持久化采用 Application Support 独立 JSON 文件 + 异步防抖写入，冷启动兼容旧 UserDefaults 迁移。
final class UnplayableBookStore: @unchecked Sendable {
    static let shared = UnplayableBookStore()

    private static let legacyDefaultsKey = "unplayableBookIDs.v1"

    private let lock = NSLock()
    private let maxCount = 3000
    private var orderedIDs: [String]
    private var idSet: Set<String>
    private var pendingPersistTask: Task<Void, Never>?
    private var persistGeneration: UInt64 = 0

    private static var storageURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DSNovel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("unplayable_books.json")
    }

    private init() {
        let fileURL = Self.storageURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            orderedIDs = decoded
            idSet = Set(decoded)
        } else if let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyDefaultsKey), !legacy.isEmpty {
            orderedIDs = legacy
            idSet = Set(legacy)
            UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
            let snapshot = legacy
            Task.detached(priority: .utility) {
                Self.writeSnapshot(snapshot, to: fileURL)
            }
        } else {
            orderedIDs = []
            idSet = []
        }
    }

    func contains(_ bookID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return idSet.contains(bookID)
    }

    func mark(_ bookID: String) {
        lock.lock()
        guard !idSet.contains(bookID) else {
            lock.unlock()
            return
        }
        idSet.insert(bookID)
        orderedIDs.append(bookID)
        if orderedIDs.count > maxCount {
            let overflow = orderedIDs.count - maxCount
            for removed in orderedIDs.prefix(overflow) { idSet.remove(removed) }
            orderedIDs.removeFirst(overflow)
        }
        schedulePersistLocked()
        lock.unlock()
    }

    func unmark(_ bookID: String) {
        lock.lock()
        guard idSet.remove(bookID) != nil else {
            lock.unlock()
            return
        }
        orderedIDs.removeAll { $0 == bookID }
        schedulePersistLocked()
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        idSet.removeAll()
        orderedIDs.removeAll()
        schedulePersistLocked()
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return idSet.count
    }

    private func schedulePersistLocked() {
        persistGeneration &+= 1
        let generation = persistGeneration
        pendingPersistTask?.cancel()
        let fileURL = Self.storageURL
        pendingPersistTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.lock.lock()
            guard self.persistGeneration == generation else {
                self.lock.unlock()
                return
            }
            let snapshot = self.orderedIDs
            self.pendingPersistTask = nil
            self.lock.unlock()
            Self.writeSnapshot(snapshot, to: fileURL)
        }
    }

    private static func writeSnapshot(_ snapshot: [String], to url: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
