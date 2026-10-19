// Run with swiftc -parse-as-library; this diagnostic is never loaded by the app UI.
import CoreML
import Foundation
import Darwin

@main
struct InspectCoreMLPlacement {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else {
            throw NSError(domain: "Recordly", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass compiled .mlmodelc directories"])
        }
        var reports: [[String: Any]] = []
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                reports.append(["model": url.deletingLastPathComponent().lastPathComponent,
                    "component": url.lastPathComponent, "status": "Not installed"])
                continue
            }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let start = ProcessInfo.processInfo.systemUptime
            let plan: MLComputePlan
            do { plan = try await MLComputePlan.load(contentsOf: url, configuration: config) }
            catch {
                let failure = error as NSError
                reports.append(["model": url.deletingLastPathComponent().lastPathComponent,
                    "component": url.lastPathComponent, "status": "Plan unavailable",
                    "errorDomain": failure.domain, "errorCode": failure.code])
                continue
            }
            var counts: [String: Int] = [:]
            func add(_ usage: MLComputePlan.DeviceUsage?) {
                let name: String
                switch usage?.preferred {
                case .cpu?: name = "CPU"
                case .gpu?: name = "GPU"
                case .neuralEngine?: name = "Neural Engine"
                case nil: name = "Unknown"
                @unknown default: name = "Other"
                }
                counts[name, default: 0] += 1
            }
            func block(_ value: MLModelStructure.Program.Block) {
                for operation in value.operations {
                    add(plan.deviceUsage(for: operation))
                    for child in operation.blocks { block(child) }
                }
            }
            func structure(_ value: MLModelStructure) {
                switch value {
                case let .program(program):
                    for function in program.functions.values { block(function.block) }
                case let .neuralNetwork(network):
                    for layer in network.layers { add(plan.deviceUsage(for: layer)) }
                case let .pipeline(pipeline):
                    for child in pipeline.subModels { structure(child) }
                default: break
                }
            }
            structure(plan.modelStructure)
            reports.append(["model": url.deletingLastPathComponent().lastPathComponent,
                "component": url.lastPathComponent, "policy": "cpuAndNeuralEngine",
                "preferredOperationCounts": counts,
                "inspectionSeconds": ProcessInfo.processInfo.systemUptime - start])
        }
        var length = 0
        sysctlbyname("hw.model", nil, &length, nil, 0)
        var hardware = [CChar](repeating: 0, count: max(1, length))
        sysctlbyname("hw.model", &hardware, &length, nil, 0)
        let output: [String: Any] = ["hardware": String(cString: hardware),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "evidence": "Preferred Core ML operation placement; not live utilization, execution time share or watts",
            "models": reports]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        print("")
    }
}
