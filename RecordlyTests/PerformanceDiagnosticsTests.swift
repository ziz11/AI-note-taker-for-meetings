import XCTest
import AVFoundation
import AppKit
import SwiftUI
@testable import Recordly

final class PerformanceDiagnosticsTests: XCTestCase {
    private func measurement(_ stage: PerformanceStage = .asr, model: String = "ultra", audio: Double? = 100,
                             elapsed: Double = 2, outcome: PerformanceOutcome = .completed) -> PerformanceMeasurement {
        .init(stage: stage, model: model, elapsedSeconds: elapsed, audioSeconds: audio,
              outcome: outcome, startedOnMainThread: false)
    }

    func testASRSpeedWeightsAudioAndRuntimeAndExcludesSetupFailuresAndOtherModels() throws {
        var state = PerformanceAccumulator()
        state.record(measurement(.modelLoad, audio: nil, elapsed: 20))
        state.record(measurement(audio: 100, elapsed: 2))
        state.record(measurement(audio: 30, elapsed: 1))
        state.record(measurement(audio: 50, elapsed: 10, outcome: .failed))
        XCTAssertEqual(try XCTUnwrap(state.asrRealtimeMultiplier), 130.0 / 3, accuracy: 0.001)
        state.record(measurement(model: "v3", audio: 30, elapsed: 3))
        XCTAssertEqual(state.asrRealtimeMultiplier, 10)
    }

    func testCPUUsesProcessTimeDeltasAndResetsAfterIdle() throws {
        var state = PerformanceAccumulator()
        func raw(_ uptime: Double, _ cpu: Double) -> PerformanceRawResources {
            .init(uptime: uptime, cpuSeconds: cpu, residentBytes: 123, thermalState: "Nominal", lowPowerMode: false)
        }
        XCTAssertNil(state.sample(raw(10, 4), mainQueueDelayMs: 2).cpuPercent)
        let sample = state.sample(raw(12, 5), mainQueueDelayMs: 3)
        XCTAssertEqual(try XCTUnwrap(sample.cpuPercent), 50, accuracy: 0.001)
        XCTAssertEqual(sample.residentBytes, 123)
        state.resetSamplingBaseline()
        XCTAssertNil(state.sample(raw(100, 9), mainQueueDelayMs: 1).cpuPercent)
        XCTAssertEqual(state.sample(raw(102, 13), mainQueueDelayMs: 1).cpuPercent, 200)
    }

    func testInvalidAndCancelledMeasurementsNeverClaimRealtimeSpeed() {
        XCTAssertNil(measurement(elapsed: 0).realtimeMultiplier)
        XCTAssertNil(measurement(audio: .nan).realtimeMultiplier)
        XCTAssertNil(measurement(outcome: .cancelled).realtimeMultiplier)
        var state = PerformanceAccumulator()
        state.record(measurement(.pipeline, audio: 600, elapsed: 20))
        XCTAssertEqual(state.lastPipeline?.realtimeMultiplier, 30)
        state.record(measurement(.pipeline, outcome: .cancelled))
        XCTAssertNil(state.lastPipeline?.realtimeMultiplier)
        XCTAssertEqual(state.lastPipeline?.outcome, .cancelled)
    }

    func testHistoryAndQueueDelayWindowAreBounded() {
        var state = PerformanceAccumulator()
        for index in 0..<200 {
            state.record(measurement(audio: Double(index + 1)))
            _ = state.sample(.init(uptime: Double(index), cpuSeconds: Double(index), residentBytes: nil,
                thermalState: "Nominal", lowPowerMode: false), mainQueueDelayMs: Double(index))
        }
        XCTAssertEqual(state.measurements.count, 96)
        XCTAssertEqual(state.samples.count, 30)
        XCTAssertEqual(state.uiDelayP95Ms, 198)
    }
    func testSamplingStopsAfterLastInterestAndCancellationDoesNotLeaveASpan() async {
        let telemetry = PerformanceTelemetry(logURL: nil, sampleInterval: 0.02)
        let first = UUID(), second = UUID()
        var snapshot = await telemetry.snapshot()
        XCTAssertFalse(snapshot.isSampling)
        telemetry.setInterest(first, active: true)
        telemetry.setInterest(second, active: true)
        telemetry.setInterest(first, active: false)
        snapshot = await telemetry.snapshot()
        XCTAssertTrue(snapshot.isSampling)
        telemetry.setInterest(second, active: false)
        snapshot = await telemetry.snapshot()
        XCTAssertFalse(snapshot.isSampling)
        let span = telemetry.begin(.pipeline)
        snapshot = await telemetry.snapshot()
        XCTAssertTrue(snapshot.isSampling)
        telemetry.end(span, audioSeconds: 600, outcome: .cancelled)
        telemetry.end(span, audioSeconds: 600)
        snapshot = await telemetry.snapshot()
        XCTAssertFalse(snapshot.isSampling)
        XCTAssertEqual(snapshot.activeSpanCount, 0)
        XCTAssertEqual(snapshot.measurements.count, 1)
        XCTAssertNil(snapshot.lastPipeline?.realtimeMultiplier)
    }

    @MainActor
    func testMainQueueDelayIsMeasuredWithoutAccumulatingAnIdleTimer() async throws {
        let telemetry = PerformanceTelemetry(logURL: nil, sampleInterval: 0.02)
        let lease = UUID()
        telemetry.setInterest(lease, active: true)
        // Allow a main-queue probe to finish, then stop and verify no late probe restarts sampling.
        try await Task.sleep(nanoseconds: 100_000_000)
        let active = await telemetry.snapshot()
        XCTAssertNotNil(active.latest)
        XCTAssertGreaterThanOrEqual(active.latest?.mainQueueDelayMs ?? -1, 0)
        XCTAssertNotNil(active.latest?.residentBytes)
        telemetry.setInterest(lease, active: false)
        let stopped = await telemetry.snapshot()
        try await Task.sleep(nanoseconds: 60_000_000)
        let later = await telemetry.snapshot()
        XCTAssertFalse(later.isSampling)
        XCTAssertEqual(later.samples.count, stopped.samples.count)
    }

    @MainActor
    func testNativePerformanceOnBoundedExcerpt() async throws {
#if arch(arm64)
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["RECORDLY_PERFORMANCE_AUDIO"],
              let models = environment["RECORDLY_PERFORMANCE_MODELS"],
              let output = environment["RECORDLY_PERFORMANCE_OUTPUT"] else {
            throw XCTSkip("Opt-in bounded native performance probe")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordly-performance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: input))
        let count = AVAudioFrameCount(min(file.length, Int64(file.processingFormat.sampleRate * 30)))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        let clip = folder.appendingPathComponent("excerpt.wav")
        do {
            let writer = try AVAudioFile(forWriting: clip, settings: buffer.format.settings)
            try writer.write(from: buffer)
        }
        let telemetry = PerformanceTelemetry.shared
        let lease = UUID()
        telemetry.setInterest(lease, active: true)
        defer { telemetry.setInterest(lease, active: false) }
        var runs: [[String: Any]] = []
        var measuredPasses = 0
        for model in FluidAudioASRModel.allCases {
            let directory = URL(fileURLWithPath: models).appendingPathComponent(model.cacheFolder)
            guard FluidAudioModelValidator.isValidModelDirectory(directory) else {
                runs.append(["model": model.rawValue, "status": "Not installed in the managed cache"])
                continue
            }
            let engine = FluidAudioASREngine(transcriber: FluidAudioTranscriber())
            for pass in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                let document = try await engine.transcribe(audioURL: clip, channel: .mic, sessionID: UUID(),
                    configuration: .init(modelURL: directory))
                let seconds = ProcessInfo.processInfo.systemUptime - start
                XCTAssertFalse(document.segments.isEmpty)
                XCTAssertTrue(document.segments.allSatisfy { segment in
                    ASRTimedText(text: segment.text, words: segment.words ?? []).isAligned
                })
                measuredPasses += 1
                runs.append(["model": model.rawValue, "pass": pass, "wallSeconds": seconds,
                    "audioSeconds": Double(count) / buffer.format.sampleRate])
            }
        }
        guard measuredPasses > 0 else { throw XCTSkip("No managed model installed") }
        try await Task.sleep(nanoseconds: 100_000_000)
        let snapshot = await telemetry.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.measurements.filter { $0.stage == .asr }.count, measuredPasses)
        XCTAssertFalse(snapshot.measurements.contains { ($0.stage == .modelLoad || $0.stage == .asr) && $0.startedOnMainThread })
        XCTAssertNotNil(snapshot.latest)
        let encoded = try JSONEncoder().encode(snapshot)
        let report: [String: Any] = ["scope": "30-second excerpt; first model call then two retained-manager repeats. Not full pipeline or an energy benchmark.",
            "runs": runs, "telemetry": try JSONSerialization.jsonObject(with: encoded)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
#else
        throw XCTSkip("Apple Silicon native acceptance")
#endif
    }

    @MainActor
    func testRenderPerformancePanel() throws {
        guard let output = ProcessInfo.processInfo.environment["RECORDLY_PERFORMANCE_RENDER"] else {
            throw XCTSkip("Opt-in native UI render")
        }
        var fixture = PerformanceSnapshot(isSampling: true, activeSpanCount: 1,
            asrRealtimeMultiplier: 50, asrModel: "ultra", lastModelLoadSeconds: 0.8, uiDelayP95Ms: 2.5)
        fixture.samples = [.init(cpuPercent: 55, residentBytes: UInt64(512 * 1024 * 1024),
            mainQueueDelayMs: 1.2, thermalState: "Nominal", lowPowerMode: false)]
        let host = NSHostingView(rootView: PerformancePanel(snapshot: fixture).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }

}
