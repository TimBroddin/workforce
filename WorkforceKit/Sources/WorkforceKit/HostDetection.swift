import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct HostInfo: Sendable {
    public let app: HostApp
    public let bundleId: String?
    public let pid: Int32?

    public init(app: HostApp, bundleId: String?, pid: Int32?) {
        self.app = app
        self.bundleId = bundleId
        self.pid = pid
    }
}

public enum HostDetection: Sendable {
    /// Walk the process tree from the current process upward to find the host app.
    public static func detect() -> HostInfo {
        #if os(macOS)
        var pid = getppid()
        for _ in 0..<10 {
            guard pid > 1 else { break }
            if let name = processName(for: pid) {
                let lowered = name.lowercased()
                if lowered.contains("terminal") {
                    return HostInfo(app: .terminal, bundleId: "com.apple.Terminal", pid: pid)
                } else if lowered.contains("iterm") {
                    return HostInfo(app: .iterm, bundleId: "com.googlecode.iterm2", pid: pid)
                } else if lowered.contains("code helper") || lowered.contains("electron") {
                    if let ppid = parentPid(of: pid), let parentName = processName(for: ppid) {
                        if parentName.lowercased().contains("cursor") {
                            return HostInfo(
                                app: .cursor,
                                bundleId: "com.todesktop.230313mzl4w4u92",
                                pid: pid
                            )
                        }
                    }
                    return HostInfo(app: .vscode, bundleId: "com.microsoft.VSCode", pid: pid)
                } else if lowered.contains("cursor") {
                    return HostInfo(
                        app: .cursor,
                        bundleId: "com.todesktop.230313mzl4w4u92",
                        pid: pid
                    )
                } else if lowered.contains("warp") {
                    return HostInfo(app: .warp, bundleId: "dev.warp.Warp-Stable", pid: pid)
                }
            }
            if let ppid = parentPid(of: pid) {
                pid = ppid
            } else {
                break
            }
        }
        return HostInfo(app: .unknown, bundleId: nil, pid: nil)
        #else
        return HostInfo(app: .unknown, bundleId: nil, pid: nil)
        #endif
    }

    #if os(macOS)
    private static func processName(for pid: Int32) -> String? {
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        let pathLength = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))
        guard pathLength > 0 else { return nil }
        let path = String(cString: pathBuffer)
        return (path as NSString).lastPathComponent
    }

    private static func parentPid(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
    #endif
}
