import Darwin
import Foundation

struct AppUsage: Equatable {
    /// Percent of one core, like Activity Monitor (can exceed 100).
    var cpu: Double = 0
    /// Physical footprint in bytes (Activity Monitor's "Memory").
    var memory: UInt64 = 0
}

/// Periodically samples CPU and memory of every process and attributes helpers
/// (renderers, XPC services) to the app responsible for them.
final class ResourceMonitor {
    /// Latest usage keyed by app pid, delivered on the main queue.
    var onUpdate: (([pid_t: AppUsage]) -> Void)?
    private(set) var usage: [pid_t: AppUsage] = [:]

    private let queue = DispatchQueue(label: "cmdtab.resources", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Touched only on `queue`.
    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var lastSample: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [weak self] in
            self?.lastCPUTime = [:]
            self?.lastSample = 0
        }
        usage = [:]
    }

    private func sample() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastSample == 0 ? 0 : now - lastSample
        var cpuTimes: [pid_t: UInt64] = [:]
        var result: [pid_t: AppUsage] = [:]

        for pid in allPIDs() {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }

            let cpuTime = toNanoseconds(info.ri_user_time + info.ri_system_time)
            cpuTimes[pid] = cpuTime
            let owner = Private.responsiblePID(for: pid)
            result[owner, default: AppUsage()].memory += info.ri_phys_footprint
            // New processes have no baseline yet; count them from the next sample.
            if elapsed > 0, let prev = lastCPUTime[pid], cpuTime >= prev {
                result[owner, default: AppUsage()].cpu += Double(cpuTime - prev) / Double(elapsed) * 100
            }
        }

        lastCPUTime = cpuTimes
        lastSample = now
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.usage = result
            self.onUpdate?(result)
        }
    }

    private func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Leave headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(n, 0))))
    }

    /// rusage CPU times are in Mach absolute time units (ticks on Apple Silicon).
    private func toNanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
