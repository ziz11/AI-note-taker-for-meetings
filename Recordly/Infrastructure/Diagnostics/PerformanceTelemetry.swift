import Combine
import Darwin
import Foundation
import os.signpost

enum PerformanceStage: String, Codable, Sendable { case modelLoad, asr, diarization, pipeline }
enum PerformanceOutcome: String, Codable, Sendable { case completed, failed, cancelled }

struct PerformanceMeasurement: Codable, Equatable, Sendable {
    var stage: PerformanceStage
    var model: String?
    var elapsedSeconds: Double
    var audioSeconds: Double?
    var outcome: PerformanceOutcome
    var startedOnMainThread: Bool
    var timestamp: Date = Date()

    var realtimeMultiplier: Double? {
        guard outcome == .completed, elapsedSeconds.isFinite, elapsedSeconds > 0,
              let audioSeconds, audioSeconds.isFinite, audioSeconds > 0 else { return nil }
        return audioSeconds / elapsedSeconds
    }
}

struct PerformanceRawResources: Sendable {
    var uptime: Double
    var cpuSeconds: Double?
    var residentBytes: UInt64?
    var thermalState: String
    var lowPowerMode: Bool
}

struct PerformanceResourceSample: Codable, Equatable, Sendable {
    var timestamp: Date = Date()
    var cpuPercent: Double?
    var residentBytes: UInt64?
    var mainQueueDelayMs: Double
    var thermalState: String
    var lowPowerMode: Bool
}

struct PerformanceAccumulator {
    private(set) var measurements: [PerformanceMeasurement] = []
    private(set) var samples: [PerformanceResourceSample] = []
    private var previousCPU: (uptime: Double, seconds: Double)?

    mutating func record(_ measurement: PerformanceMeasurement) {
        measurements.append(measurement)
        if measurements.count > 96 { measurements.removeFirst(measurements.count - 96) }
    }

    var asrRealtimeMultiplier: Double? {
        guard let model = measurements.last(where: { $0.stage == .asr && $0.realtimeMultiplier != nil })?.model else { return nil }
        let work = measurements.filter { $0.stage == .asr && $0.model == model && $0.realtimeMultiplier != nil }
        let seconds = work.reduce(0) { $0 + $1.elapsedSeconds }
        return seconds > 0 ? work.reduce(0) { $0 + ($1.audioSeconds ?? 0) } / seconds : nil
    }
    var lastPipeline: PerformanceMeasurement? { measurements.last { $0.stage == .pipeline } }
    var uiDelayP95Ms: Double? {
        let values = samples.map(\.mainQueueDelayMs).sorted()
        guard !values.isEmpty else { return nil }
        return values[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)]
    }

    mutating func resetSamplingBaseline() { previousCPU = nil }

    mutating func sample(_ raw: PerformanceRawResources, mainQueueDelayMs: Double) -> PerformanceResourceSample {
        var cpuPercent: Double?
        if let cpu = raw.cpuSeconds, cpu.isFinite, raw.uptime.isFinite {
            if let previousCPU, raw.uptime > previousCPU.uptime, cpu >= previousCPU.seconds {
                cpuPercent = (cpu - previousCPU.seconds) / (raw.uptime - previousCPU.uptime) * 100
            }
            previousCPU = (raw.uptime, cpu)
        } else { previousCPU = nil }
        let result = PerformanceResourceSample(cpuPercent: cpuPercent, residentBytes: raw.residentBytes,
            mainQueueDelayMs: max(0, mainQueueDelayMs), thermalState: raw.thermalState, lowPowerMode: raw.lowPowerMode)
        samples.append(result)
        if samples.count > 30 { samples.removeFirst(samples.count - 30) }
        return result
    }
}


struct PerformanceSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var asrComputePolicy = "cpuAndNeuralEngine (configured)"
    var diarizationComputePolicy = "all (GPU allowed)"
    var evidenceNote = "CPU is process CPU; UI delay is main-queue scheduling. ANE utilization and per-app watts are not measured."
    var timestamp: Date = Date()
    var isSampling = false
    var activeSpanCount = 0
    var asrRealtimeMultiplier: Double?
    var asrModel: String?
    var lastPipeline: PerformanceMeasurement?
    var lastModelLoadSeconds: Double?
    var uiDelayP95Ms: Double?
    var samples: [PerformanceResourceSample] = []
    var measurements: [PerformanceMeasurement] = []
    var latest: PerformanceResourceSample? { samples.last }
}

struct PerformanceSpan: Sendable {
    let id: UUID
    let stage: PerformanceStage
    let model: String?
    let uptime: Double
    let startedOnMainThread: Bool
}

/// All mutable sampling state and file I/O belong to one utility queue.
/// Nothing here reads audio, transcripts, session titles or private power sensors.
final class PerformanceTelemetry: @unchecked Sendable {
    static let shared = PerformanceTelemetry(logURL: defaultLogURL)
    static var defaultLogURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["RECORDLY_PERFORMANCE_LOG"] { return URL(fileURLWithPath: path) }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Recordly/diagnostics/performance.jsonl")
    }
    let updates = PassthroughSubject<PerformanceSnapshot, Never>()
    private let queue = DispatchQueue(label: "Recordly.Performance", qos: .utility)
    private let logURL: URL?
    private let sampleInterval: Double
    private var accumulator = PerformanceAccumulator()
    private var spans = Set<UUID>()
    private var signposts: [UUID: OSSignpostID] = [:]
    private static let signpostLog = OSLog(subsystem: "com.local.Recordly", category: "Performance")
    private var interests = Set<UUID>()
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var probePending = false
    private let maxLogBytes = 262_144

    init(logURL: URL?, sampleInterval: Double = 2) {
        self.logURL = logURL
        self.sampleInterval = max(0.02, sampleInterval)
    }

    func begin(_ stage: PerformanceStage, model: String? = nil) -> PerformanceSpan {
        let span = PerformanceSpan(id: UUID(), stage: stage, model: model,
            uptime: ProcessInfo.processInfo.systemUptime, startedOnMainThread: Thread.isMainThread)
        queue.async { [self] in
            spans.insert(span.id)
            let signpost = OSSignpostID(log: Self.signpostLog)
            signposts[span.id] = signpost
            os_signpost(.begin, log: Self.signpostLog, name: "Recordly Stage", signpostID: signpost,
                        "%{public}@ %{public}@", span.stage.rawValue, span.model ?? "pipeline")
            updateSampling()
        }
        return span
    }

    func end(_ span: PerformanceSpan, audioSeconds: Double? = nil, outcome: PerformanceOutcome = .completed) {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - span.uptime)
        queue.async { [self] in
            guard spans.remove(span.id) != nil else { return }
            if let signpost = signposts.removeValue(forKey: span.id) {
                os_signpost(.end, log: Self.signpostLog, name: "Recordly Stage", signpostID: signpost,
                            "%{public}@", outcome.rawValue)
            }
            let item = PerformanceMeasurement(stage: span.stage, model: span.model,
                elapsedSeconds: elapsed, audioSeconds: audioSeconds, outcome: outcome,
                startedOnMainThread: span.startedOnMainThread)
            accumulator.record(item)
            appendLog(item)
            updateSampling()
            // Periodic sampling publishes window events; job completion publishes immediately.
            if span.stage == .pipeline || timer == nil { emit() }
        }
    }

    func setInterest(_ id: UUID, active: Bool) {
        queue.async { [self] in
            if active { interests.insert(id) } else { interests.remove(id) }
            updateSampling()
        }
    }

    func requestSnapshot() { queue.async { [self] in emit() } }

    func snapshot() async -> PerformanceSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: currentSnapshot()) }
        }
    }

    private func currentSnapshot() -> PerformanceSnapshot {
        PerformanceSnapshot(isSampling: timer != nil, activeSpanCount: spans.count,
            asrRealtimeMultiplier: accumulator.asrRealtimeMultiplier,
            asrModel: accumulator.measurements.last { $0.stage == .asr && $0.realtimeMultiplier != nil }?.model,
            lastPipeline: accumulator.lastPipeline,
            lastModelLoadSeconds: accumulator.measurements.last { $0.stage == .modelLoad && $0.outcome == .completed }?.elapsedSeconds,
            uiDelayP95Ms: accumulator.uiDelayP95Ms, samples: accumulator.samples, measurements: accumulator.measurements)
    }

    private func emit() { updates.send(currentSnapshot()) }

    private func updateSampling() {
        let needed = !spans.isEmpty || !interests.isEmpty
        if needed && timer == nil {
            generation += 1
            accumulator.resetSamplingBaseline()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: sampleInterval,
                            leeway: .milliseconds(Int(min(0.25, sampleInterval / 4) * 1000)))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source
            source.resume()
        } else if !needed && timer != nil {
            generation += 1
            timer?.cancel()
            timer = nil
            probePending = false
            accumulator.resetSamplingBaseline()
            emit()
        }
    }

    private func sample() {
        guard timer != nil, !probePending else { return }
        // One probe maximum: a blocked main queue must not accumulate a backlog of probes.
        probePending = true
        let token = generation
        let raw = Self.readResources()
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            let delay = max(0, ProcessInfo.processInfo.systemUptime - started) * 1000
            self?.queue.async { [weak self] in
                guard let self, self.timer != nil, self.generation == token else { return }
                self.probePending = false
                let resource = self.accumulator.sample(raw, mainQueueDelayMs: delay)
                self.appendLog(resource)
                self.emit()
            }
        }
    }

    private static func readResources() -> PerformanceRawResources {
        var usage = rusage()
        let cpu: Double?
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        } else { cpu = nil }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        return .init(uptime: ProcessInfo.processInfo.systemUptime, cpuSeconds: cpu,
            residentBytes: result == KERN_SUCCESS ? info.resident_size : nil,
            thermalState: thermal, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func appendLog<T: Encodable>(_ value: T) {
        guard let logURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(value)
            data.append(0x0A)
            let fm = FileManager.default
            try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber,
               size.intValue + data.count > maxLogBytes {
                let previous = logURL.deletingPathExtension().appendingPathExtension("previous.jsonl")
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try fm.moveItem(at: logURL, to: previous)
            }
            if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never fail, retry, or interrupt audio/inference work.
        }
    }
}

@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var snapshot = PerformanceSnapshot()
    let telemetry: PerformanceTelemetry
    private let interestID = UUID()
    private var panelOpen = false
    private var captureActive = false
    private var subscription: AnyCancellable?

    init(telemetry: PerformanceTelemetry = .shared) {
        self.telemetry = telemetry
        subscription = telemetry.updates.receive(on: DispatchQueue.main).sink { [weak self] in self?.snapshot = $0 }
        telemetry.requestSnapshot()
    }

    func setPanelOpen(_ open: Bool) { panelOpen = open; updateInterest() }
    func setCaptureActive(_ active: Bool) { captureActive = active; updateInterest() }
    private func updateInterest() { telemetry.setInterest(interestID, active: panelOpen || captureActive) }
    deinit { telemetry.setInterest(interestID, active: false) }
}
