import XCTest
@testable import Recordly

final class CaptureSamplePipelineTests: XCTestCase {
    func testDeliversElementsInOrderAndDrainsOnFinish() async {
        let received = LockedBox<[Int]>([])
        let pipeline = CaptureSamplePipeline<Int>(bufferLimit: 128) { value in
            received.mutate { $0.append(value) }
        }
        for value in 0..<100 { pipeline.submit(value) }
        await pipeline.finish()
        XCTAssertEqual(received.value, Array(0..<100))
        XCTAssertEqual(pipeline.droppedCount, 0)
    }

    func testSubmitAfterFinishIsIgnored() async {
        let received = LockedBox<[Int]>([])
        let pipeline = CaptureSamplePipeline<Int>(bufferLimit: 8) { value in
            received.mutate { $0.append(value) }
        }
        pipeline.submit(1)
        await pipeline.finish()
        pipeline.submit(2)
        XCTAssertEqual(received.value, [1])
    }

    func testCountsDroppedElementsOnOverflow() async {
        let gate = AsyncGate()
        let pipeline = CaptureSamplePipeline<Int>(bufferLimit: 2) { _ in
            await gate.wait()
        }
        for value in 0..<50 { pipeline.submit(value) }
        await gate.open()
        await pipeline.finish()
        XCTAssertGreaterThan(pipeline.droppedCount, 0)
    }

    func testMeteringThrottleLimitsRate() {
        let throttle = MeteringThrottle(interval: 60)
        XCTAssertTrue(throttle.due())
        XCTAssertFalse(throttle.due())
        XCTAssertFalse(throttle.due())
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stored)
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
