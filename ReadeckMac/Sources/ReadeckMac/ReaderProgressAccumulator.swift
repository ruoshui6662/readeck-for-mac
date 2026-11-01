struct ReaderProgressAccumulator {
    private var lastReported: Int
    private var pending: Int?

    init(initial: Int) {
        lastReported = min(max(initial, 0), 100)
    }

    mutating func record(_ value: Int) {
        let value = min(max(value, 0), 100)
        guard value > lastReported + 4 else { return }
        pending = max(value, pending ?? value)
    }

    mutating func flush() -> Int? {
        guard let pending else { return nil }
        self.pending = nil
        guard pending > lastReported + 4 else { return nil }
        lastReported = pending
        return pending
    }
}
