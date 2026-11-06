/// Opt-in diagnostics retain a fixed-size chronological tail. Appending never
/// shifts the existing samples; only an explicit snapshot allocates an array.
struct PreviewDiagnosticBuffer<Element> {
    let capacity: Int
    private var storage: [Element?]
    private var next = 0
    private(set) var count = 0
    private(set) var totalAppended = 0
    var overwrittenCount: Int { totalAppended - count }

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[next] = element
        next = (next + 1) % capacity
        if count < capacity { count += 1 }
        totalAppended += 1
    }

    var values: [Element] {
        let first = count == capacity ? next : 0
        return (0..<count).map { storage[(first + $0) % capacity]! }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        next = 0; count = 0; totalAppended = 0
    }
}
