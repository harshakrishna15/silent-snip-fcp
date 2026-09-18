import Foundation

/// Job-local completion fallback when Final Cut omits its XML Open event.
/// Compare bytes on every read, but parse only when they change. Missing,
/// empty, invalid, or replaced data cannot inherit earlier stability evidence.
struct StableXMLDelivery {
    private var previous: Data?
    private var valid = false
    private var stableReads = 0

    mutating func observe(_ data: Data?, validate: (Data) -> Bool) -> Bool {
        guard let data, !data.isEmpty else {
            self = Self()
            return false
        }
        if data != previous {
            previous = data
            valid = validate(data)
            stableReads = 0
        } else if valid {
            stableReads += 1
        }
        // Keep the existing three seconds of stable 100 ms reads. This is
        // only an XML fallback; rendered audio still requires host completion.
        return valid && stableReads >= 30
    }
}
