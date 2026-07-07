import Foundation

/// Single-consumer pipeline for high-rate capture callbacks: the producer
/// side is non-blocking (drop-newest on overflow), one long-lived Task
/// consumes elements in order. Replaces per-buffer `Task {}` spawns.
final class CaptureSamplePipeline<Element: Sendable>: @unchecked Sendable {
    private let continuation: AsyncStream<Element>.Continuation
    private let consumer: Task<Void, Never>
    private let lock = NSLock()
    private var dropped = 0
    private var finished = false

    var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    init(bufferLimit: Int = 64, handler: @escaping @Sendable (Element) async -> Void) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: .bufferingOldest(bufferLimit)) {
            continuation = $0
        }
        self.continuation = continuation
        self.consumer = Task {
            for await element in stream {
                await handler(element)
            }
        }
    }

    func submit(_ element: Element) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        lock.unlock()
        if case .dropped = continuation.yield(element) {
            lock.lock()
            dropped += 1
            lock.unlock()
        }
    }

    /// Stops intake and waits until every buffered element has been handled.
    func finish() async {
        markFinished()
        continuation.finish()
        await consumer.value
    }

    private func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

/// Rate limiter for UI metering work inside a pipeline handler.
/// One per pipeline; only ever touched from that pipeline's consumer Task.
final class MeteringThrottle: @unchecked Sendable {
    private var lastUptime: TimeInterval = 0
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func due() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUptime >= interval else { return false }
        lastUptime = now
        return true
    }
}
