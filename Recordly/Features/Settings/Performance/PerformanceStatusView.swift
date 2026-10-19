import AppKit
import SwiftUI

struct PerformanceStatusButton: View {
    @ObservedObject var monitor: PerformanceMonitor
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "cpu")
                .font(.system(size: 12))
                .foregroundStyle(monitor.snapshot.activeSpanCount > 0 ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compute and performance")
        .help("Neural Engine policy and performance")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PerformancePanel(snapshot: monitor.snapshot)
        }
        .onChange(of: isPresented) { _, open in monitor.setPanelOpen(open) }
        .onDisappear { monitor.setPanelOpen(false) }
    }
}

struct PerformancePanel: View {
    let snapshot: PerformanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compute & Performance").fontWeight(.semibold)
                Spacer()
                Text(snapshot.isSampling ? "Live" : "Last sample")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
#if arch(arm64)
                metric("ASR policy", "CPU + Neural Engine")
#else
                metric("ASR", "Apple Silicon required")
#endif
                metric("Speakers policy", "Automatic · GPU allowed")
                Text("Configured devices, not measured utilization.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(spacing: 7) {
                metric("ASR · \(snapshot.asrModel ?? "no samples")", speed(snapshot.asrRealtimeMultiplier))
                    .help("Input audio duration / measured ASR time; model loading is excluded. Recent samples from the last model only.")
                metric("Pipeline · includes cache", pipelineValue)
                    .help("Whole recording duration / full job time, excluding queue wait. Cache reuse can increase this ratio.")
                metric("Model load", snapshot.lastModelLoadSeconds.map { String(format: "%.2f s", $0) } ?? "—")
                metric("App CPU", snapshot.latest?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    .help("Process CPU time / elapsed time. 100% means one CPU core; this is not Neural Engine load.")
                metric("Resident memory", snapshot.latest?.residentBytes.map {
                    ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory)
                } ?? "—")
                metric("UI queue · p95", snapshot.uiDelayP95Ms.map { String(format: "%.1f ms", $0) } ?? "—")
                    .help("Main-queue scheduling delay over the last 30 probes, not display FPS or a complete frame-time measurement.")
                metric("System thermal", snapshot.latest?.thermalState ?? "—")
                metric("Low Power Mode", snapshot.latest.map { $0.lowPowerMode ? "On" : "Off" } ?? "—")
            }
            Divider()
            Text("ANE utilization and app watts require separate profiling. Thermal state and Low Power Mode are not energy measurements.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Samples every 2s while active.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy report") { copyReport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(16)
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppTheme.contentBackground)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }

    private func speed(_ value: Double?) -> String {
        value.map { String(format: "%.1f× real-time", $0) } ?? "—"
    }

    private var pipelineValue: String {
        guard let measurement = snapshot.lastPipeline else { return "—" }
        switch measurement.outcome {
        case .completed: return speed(measurement.realtimeMultiplier)
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    private func copyReport() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
