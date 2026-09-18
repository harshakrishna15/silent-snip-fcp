import Foundation

/// Keep only bounded receipt locations between operations. Complete XML is loaded
/// for a verification attempt and released afterward; evicted receipts stay on disk.
struct PendingVerificationRegistry {
    private var locations: [UUID: URL] = [:]
    private var order: [UUID] = []
    let capacity: Int
    init(capacity: Int = 24) { self.capacity = max(1, capacity) }
    var count: Int { locations.count }
    subscript(id: UUID) -> URL? { locations[id] }

    mutating func remember(_ id: UUID, at url: URL) {
        locations[id] = url
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity { locations.removeValue(forKey: order.removeFirst()) }
    }
    mutating func remove(_ id: UUID) {
        locations.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }
    mutating func removeAll() { locations.removeAll(); order.removeAll() }
}
