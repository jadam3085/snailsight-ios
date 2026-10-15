import Foundation
import os
import SnailSightCore

/// 9.1.61: memory telemetry so a future kill is diagnosable from the session log (ev "mem", every 10 s and on every
/// thermal change / memory warning). footprint = the number iOS compares with the per-app jetsam limit
/// (task_vm_info.phys_footprint); available = os_proc_available_memory (bytes left before that limit).
enum MemoryProbe {
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func availableMB() -> Double? {
        let b = os_proc_available_memory()
        return b > 0 ? Double(b) / 1_048_576 : nil
    }

    /// Bytes this process has written since launch: logical writes (what iOS's diskwrites_resource monitor counts, incl.
    /// dirtied file-backed memory) and physical disk I/O. proc_pid_rusage is not in the iOS SDK headers but is public libc.
    static func diskWritesMB() -> (logical: Double, physical: Double)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { proc_pid_rusage_(getpid(), RUSAGE_INFO_V4, UnsafeMutableRawPointer($0)) }
        guard rc == 0 else { return nil }
        return (Double(info.ri_logical_writes) / 1_048_576, Double(info.ri_diskio_byteswritten) / 1_048_576)
    }

    /// Log fields: footprint_mb, avail_mb, limit_mb (= footprint + available, the effective per-app limit).
    static func fields() -> [String: LogValue] {
        var out: [String: LogValue] = [:]
        let f = footprintMB(), a = availableMB()
        if let f { out["footprint_mb"] = .double((f * 10).rounded() / 10) }
        if let a { out["avail_mb"] = .double((a * 10).rounded() / 10) }
        if let f, let a { out["limit_mb"] = .double(((f + a) * 10).rounded() / 10) }
        if let w = diskWritesMB() {
            out["writes_logical_mb"] = .double((w.logical * 10).rounded() / 10)
            out["writes_disk_mb"] = .double((w.physical * 10).rounded() / 10)
        }
        return out
    }
}

@_silgen_name("proc_pid_rusage")
private func proc_pid_rusage_(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32
