import Foundation

/// Hardware clock changes are not instantaneous, so a readback immediately
/// after a set can still report the old value. Poll until it settles.
func pollUntilMatches<T>(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.2,
    read: () throws -> T,
    matches: (T) -> Bool
) throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    var latest = try read()
    while !matches(latest) && Date() < deadline {
        Thread.sleep(forTimeInterval: interval)
        latest = try read()
    }
    return latest
}
