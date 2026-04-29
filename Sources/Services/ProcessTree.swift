import AppKit
import Darwin
import Foundation

/// Walks process parent-pid relationships via `sysctl` to figure out
/// which host app (Terminal, iTerm2, VSCode, etc.) is hosting a given
/// claude process. Used by external-session adoption: a `claude`
/// process's parent chain is typically `claude -> shell -> terminal`,
/// and we need the terminal app's PID to find its window via AX.
enum ProcessTree {
    /// Returns the parent PID of `pid`, or nil if it can't be looked
    /// up. Uses the `KERN_PROC_PID` sysctl which is available without
    /// special entitlements.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
            sysctl(mibPtr.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// Walks the parent chain from `pid` upward, returning the first
    /// PID whose `NSRunningApplication.bundleIdentifier` is in
    /// `knownBundleIDs`. The "host" of a claude process is typically
    /// 2-3 levels up the chain (claude → shell → terminal). Note
    /// that iTerm2's restorable-sessions feature parents shells
    /// under `iTermServer`, breaking this walk; the tty-based lookup
    /// in `HostWindowResolver` handles that case.
    static func findHostAppPID(for pid: pid_t, knownBundleIDs: Set<String>) -> pid_t? {
        var current = pid
        for _ in 0..<20 {
            guard let parent = parentPID(of: current) else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               let bundleID = app.bundleIdentifier,
               knownBundleIDs.contains(bundleID) {
                return parent
            }
            current = parent
        }
        return nil
    }

    /// Returns the path to the controlling terminal device for `pid`,
    /// e.g. `/dev/ttys013`. Returns nil if the process has no
    /// controlling tty (background daemons) or the lookup fails.
    static func controllingTTY(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
            sysctl(mibPtr.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1 else { return nil }
        guard let cstr = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: cstr)
    }
}
