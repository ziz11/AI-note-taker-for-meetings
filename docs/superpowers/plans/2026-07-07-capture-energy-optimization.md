# Capture Energy Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut CPU/energy of live recording by removing per-buffer Task spawns and per-buffer MainActor work, plus add measurement tooling.

**Architecture:** A small generic `CaptureSamplePipeline` (AsyncStream + one long-lived consumer Task) replaces the per-buffer `Task {}` spawns in `AudioCaptureService.startCapture`. Metering and error bookkeeping hop to MainActor at most ~10×/sec instead of per buffer. ScreenCaptureKit config gets explicit minimal-video settings. `os_signpost` + a powermetrics script provide the measurement discipline.

**Tech Stack:** Swift concurrency (AsyncStream), ScreenCaptureKit, Accelerate (vDSP), os.signpost, XCTest.

## Global Constraints

- macOS deployment target 15.0; arm64 only.
- Test command: `xcodebuild test -scheme Recordly -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- New test files must be registered in `Recordly.xcodeproj/project.pbxproj` (old-style pbxproj: PBXBuildFile + PBXFileReference + group child + sources phase, 4 entries — follow `CA0000012F10000000000001`-style IDs used for DirectPCMMixServiceTests).
- All 195 existing tests stay green after every task.

---

### Task 1: CaptureSamplePipeline

**Files:**
- Create: `Recordly/Infrastructure/Capture/CaptureSamplePipeline.swift`
- Test: `RecordlyTests/CaptureSamplePipelineTests.swift` (+ pbxproj registration)

**Interfaces:**
- Produces:
  - `final class CaptureSamplePipeline<Element: Sendable>: @unchecked Sendable`
  - `init(bufferLimit: Int = 64, handler: @escaping @Sendable (Element) async -> Void)`
  - `func submit(_ element: Element)` — non-blocking; drops newest on overflow and increments `droppedCount`
  - `func finish() async` — stops intake, waits until every buffered element has been handled (drain)
  - `var droppedCount: Int { get }`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Recordly

final class CaptureSamplePipelineTests: XCTestCase {
    func testDeliversElementsInOrderAndDrainsOnFinish() async {
        let received = LockedBox<[Int]>([])
        let pipeline = CaptureSamplePipeline<Int>(bufferLimit: 64) { value in
            received.mutate { $0.append(value) }
        }
        for value in 0..<100 { pipeline.submit(value) }
        await pipeline.finish()
        XCTAssertEqual(received.value, Array(0..<100))
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
        gate.open()
        await pipeline.finish()
        XCTAssertGreaterThan(pipeline.droppedCount, 0)
    }
}

/// Test helpers
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

actor AsyncGate {
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
```

- [ ] **Step 2: Run tests, expect FAIL (type not found)**
- [ ] **Step 3: Implement**

```swift
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

    func finish() async {
        lock.lock()
        finished = true
        lock.unlock()
        continuation.finish()
        await consumer.value
    }
}
```

- [ ] **Step 4: Register test file in pbxproj, run suite, expect PASS**
- [ ] **Step 5: Commit** `perf(capture): add CaptureSamplePipeline for buffer fan-in`

---

### Task 2: Wire pipelines into AudioCaptureService + throttled metering

**Files:**
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift` (startCapture ~886-916, stopCapture ~1037, properties ~820)

**Interfaces:**
- Consumes: `CaptureSamplePipeline` from Task 1.
- Produces: two `private var` pipelines on `AudioCaptureService`: `systemSamplePipeline`, `microphoneSamplePipeline` of type `CaptureSamplePipeline<CMSampleBuffer>?`; metering interval constant `meteringInterval: TimeInterval = 0.1`.

- [ ] **Step 1: Replace per-buffer Tasks in startCapture**

In `startCapture`, before `screenCaptureService.startCapture`, build pipelines (capture `streamSysWriter`/`streamMicWriter` strongly, service weakly). Level/error updates hop to MainActor at most every 100 ms via a per-pipeline throttle object (single consumer Task → no races):

```swift
/// One per pipeline; only ever touched from that pipeline's consumer Task.
final class MeteringThrottle: @unchecked Sendable {
    private var lastUptime: TimeInterval = 0
    private let interval: TimeInterval
    init(interval: TimeInterval = 0.1) { self.interval = interval }
    func due() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUptime >= interval else { return false }
        lastUptime = now
        return true
    }
}

let systemMeter = MeteringThrottle()
let systemPipeline = CaptureSamplePipeline<CMSampleBuffer>(bufferLimit: 64) { [weak self] sampleBuffer in
    do {
        try await streamSysWriter.append(sampleBuffer: sampleBuffer)
        guard let self else { return }
        if systemMeter.due() {
            let level = sampleBuffer.normalizedLevel
            await MainActor.run {
                self.systemLevelValue = level
                self.lastSystemSampleAt = Date()
                self.systemAppendErrorCount = 0
                self.systemStatusLabelValue = "Captured"
            }
        }
    } catch {
        await streamSysWriter.recordDiagnostic("system append failed: \(error.localizedDescription)")
        guard let self else { return }
        await MainActor.run {
            self.systemAppendErrorCount += 1
            self.systemStatusLabelValue = "System write error"
        }
    }
}
```

Same pattern for microphone with its own `MeteringThrottle` (append + throttled `microphoneLevelValue`, errors silently kept as today). SCK callbacks become `systemPipeline.submit(sampleBuffer)` / `microphonePipeline.submit(sampleBuffer)`. Store both in properties. `MeteringThrottle` lives in `CaptureSamplePipeline.swift` (unit-testable: `due()` true, then false immediately after).

- [ ] **Step 2: Drain in stopCapture**

After `screenCaptureService.stopCapture()` and before writer finalize:

```swift
await systemSamplePipeline?.finish()
await microphoneSamplePipeline?.finish()
if let systemSamplePipeline, systemSamplePipeline.droppedCount > 0 {
    try? await metadataStore.appendNote(
        "system pipeline dropped \(systemSamplePipeline.droppedCount) buffers", in: sessionDirectory)
}
systemSamplePipeline = nil
microphoneSamplePipeline = nil
```

Also nil both in the `defer` reset block and the startCapture error path.

- [ ] **Step 3: Run full suite, expect 195+3 PASS**
- [ ] **Step 4: Commit** `perf(capture): route sample buffers through pipelines, throttle metering`

---

### Task 3: SCK minimal-video config + vDSP RMS

**Files:**
- Modify: `Recordly/Infrastructure/Capture/AudioCaptureService.swift` (SCStreamConfiguration ~767, normalizedLevel ~1210)

- [ ] **Step 1: Config lines after `config.queueDepth = 8`**

```swift
// Audio-only capture: keep the video leg of the stream as cheap as possible.
config.width = 2
config.height = 2
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
config.showsCursor = false
```

- [ ] **Step 2: Replace scalar RMS loop in `normalizedLevel` with vDSP**

Locate the per-sample loop at the end of `normalizedLevel` and replace with `vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))` (Float32 path; keep existing non-float fallback returning 0). `import Accelerate` already present via other files — add to this file if missing.

- [ ] **Step 3: Run suite, PASS; Commit** `perf(capture): minimal SCK video config, vDSP metering`

---

### Task 4: os_signpost instrumentation

**Files:**
- Modify: `Recordly/Infrastructure/Capture/SessionMergeService.swift`, `Recordly/Infrastructure/Capture/AudioCaptureService.swift`

- [ ] **Step 1: Add signposter**

```swift
import os.signpost
private static let signposter = OSSignposter(subsystem: "com.recordly.capture", category: "pipeline")
```

Intervals: `mergeSession` wraps prepare/mix/finalize (`beginInterval("merge.mix")` etc.); `PCMTrackWriter.flushStagingBufferThrowing` wraps file write (`"capture.flush"`); `exportDurableTrackIfNeeded` wraps export. Per-flush only — never per buffer.

- [ ] **Step 2: Run suite, PASS; Commit** `chore(capture): os_signpost intervals for capture and merge`

---

### Task 5: energy-baseline.sh

**Files:**
- Create: `scripts/energy-baseline.sh` (chmod +x)

- [ ] **Step 1: Write script**

```bash
#!/bin/bash
# Usage: ./scripts/energy-baseline.sh [seconds]
# Samples Recordly CPU usage for N seconds (default 60) and prints the average.
# With sudo, also reports powermetrics energy impact.
set -euo pipefail
DURATION="${1:-60}"
PID=$(pgrep -x Recordly | head -1) || { echo "Recordly not running"; exit 1; }
echo "Sampling Recordly (pid $PID) for ${DURATION}s..."
SAMPLES=0; TOTAL=0
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
    CPU=$(ps -o %cpu= -p "$PID" | tr -d ' ')
    TOTAL=$(echo "$TOTAL + $CPU" | bc)
    SAMPLES=$((SAMPLES + 1))
    sleep 1
done
echo "Average CPU: $(echo "scale=1; $TOTAL / $SAMPLES" | bc)% over $SAMPLES samples"
if [ "$(id -u)" = "0" ]; then
    powermetrics --samplers tasks -i "$((DURATION * 1000))" -n 1 2>/dev/null \
        | grep -A2 -i recordly || true
else
    echo "(run with sudo for powermetrics energy impact)"
fi
```

- [ ] **Step 2: `bash -n` syntax check; Commit** `chore: energy baseline measurement script`

---

## Verification

1. Full suite green (198 tests).
2. Manual: record 2 min with system audio → meters move, both tracks in merged-call.m4a, no dropped-buffer notes in capture-session.json.
3. `./scripts/energy-baseline.sh 60` during a recording — record the number as the project baseline in the spec doc.
