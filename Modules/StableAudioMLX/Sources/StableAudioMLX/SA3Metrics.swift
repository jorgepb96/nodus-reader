import Darwin
import Foundation

/// Process memory as the system accounts it (`phys_footprint`, what jetsam limits).
public enum ProcessMemory {
    public static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    #if os(iOS)
    /// Remaining bytes before the app hits its memory limit (iOS 13+).
    public static func available() -> Int64 {
        Int64(os_proc_available_memory())
    }
    #endif
}

/// Samples `phys_footprint` on a background timer and keeps the maximum.
public final class PeakFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64 = 0
    private var timer: DispatchSourceTimer?

    public init() {}

    public func start(interval: DispatchTimeInterval = .milliseconds(20)) {
        lock.lock()
        peak = ProcessMemory.footprint()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    public func sample() {
        let value = ProcessMemory.footprint()
        lock.lock()
        if value > peak { peak = value }
        lock.unlock()
    }

    @discardableResult
    public func stop() -> Int64 {
        timer?.cancel()
        timer = nil
        sample()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

public enum ThermalStateName {
    public static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    public static var current: String { describe(ProcessInfo.processInfo.thermalState) }
}

/// Timings of one generation, in seconds. Load stages are zero when the stage was
/// already resident.
public struct SA3Timings: Codable, Sendable {
    public var encoderLoad: Double = 0
    public var encode: Double = 0
    public var tokenizerLoad: Double = 0
    public var t5Load: Double = 0
    public var t5Encode: Double = 0
    public var ditLoad: Double = 0
    public var sampling: Double = 0
    public var steps: [Double] = []
    public var decoderLoad: Double = 0
    public var decode: Double = 0
    public var unload: Double = 0
    public var total: Double = 0

    public var loading: Double { encoderLoad + tokenizerLoad + t5Load + ditLoad + decoderLoad }
    public var compute: Double { t5Encode + sampling + decode }
}

public struct SA3Measurement: Codable, Sendable {
    public var model: String
    public var prompt: String
    public var seconds: Double
    public var steps: Int
    public var seed: UInt64
    public var residency: String
    public var timings: SA3Timings
    /// Peak `phys_footprint` of the process during the generation.
    public var peakFootprintBytes: Int64
    /// Footprint before the generation started.
    public var baselineFootprintBytes: Int64
    /// Footprint after the generation (and unloading, when staged).
    public var endFootprintBytes: Int64
    /// MLX allocator peak (active + cache) during the generation.
    public var mlxPeakBytes: Int64
    public var thermalStart: String
    public var thermalEnd: String
    /// Generated seconds per wall-clock second.
    public var realtimeFactor: Double { seconds / max(timings.total, 1e-9) }
}
