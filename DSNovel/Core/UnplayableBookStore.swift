import Foundation

/// 「无法播放」书籍黑名单：当书籍详情确认没有任何可播放章节时记录，
/// 之后在搜索与发现的结果解码阶段直接过滤，避免用户再次点进空书。
/// 线程安全，可在任意线程读写；最多保留 3000 条，超出后淘汰最早记录。
final class UnplayableBookStore: @unchecked Sendable {
    static let shared = UnplayableBookStore()

    private let lock = NSLock()
    private let defaultsKey = "unplayableBookIDs.v1"
    private let maxCount = 3000
    private var orderedIDs: [String]
    private var idSet: Set<String>

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: "unplayableBookIDs.v1") ?? []
        orderedIDs = saved
        idSet = Set(saved)
    }

    func contains(_ bookID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return idSet.contains(bookID)
    }

    func mark(_ bookID: String) {
        lock.lock(); defer { lock.unlock() }
        guard !idSet.contains(bookID) else { return }
        idSet.insert(bookID)
        orderedIDs.append(bookID)
        if orderedIDs.count > maxCount {
            let overflow = orderedIDs.count - maxCount
            for removed in orderedIDs.prefix(overflow) { idSet.remove(removed) }
            orderedIDs.removeFirst(overflow)
        }
        persistLocked()
    }

    func unmark(_ bookID: String) {
        lock.lock(); defer { lock.unlock() }
        guard idSet.remove(bookID) != nil else { return }
        orderedIDs.removeAll { $0 == bookID }
        persistLocked()
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        idSet.removeAll()
        orderedIDs.removeAll()
        persistLocked()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return idSet.count
    }

    private func persistLocked() {
        UserDefaults.standard.set(orderedIDs, forKey: defaultsKey)
    }
}
