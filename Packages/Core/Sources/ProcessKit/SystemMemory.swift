import Darwin

/// How much of the memory of the Mac is in use.
public enum SystemMemory {
    /// The bytes that Activity Monitor calls "Memory Used": the pages of apps (the internal ones, less those that the
    /// system may purge), the wired ones and those that the compressor holds. The cached files and the free pages are
    /// not in it, for the system gives them up as soon as something asks for the room. `nil` if the system does not
    /// answer.
    public static func inUse() -> UInt64? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard status == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return inUse(
            apps: UInt64(statistics.internal_page_count), purgeable: UInt64(statistics.purgeable_count),
            wired: UInt64(statistics.wire_count), compressed: UInt64(statistics.compressor_page_count),
            pageSize: UInt64(pageSize))
    }

    /// The bytes of the given page counts, `apps` being the internal pages. `nil` if they cannot be right: the kernel
    /// keeps the counters one by one, so a read may catch more purgeable pages than internal ones, and a purgeable
    /// page is one of the internal ones.
    static func inUse(
        apps: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64
    ) -> UInt64? {
        let (kept, underflow) = apps.subtractingReportingOverflow(purgeable)
        guard !underflow else { return nil }
        let (pages, pagesOverflow) = kept.addingReportingOverflow(wired)
        let (all, allOverflow) = pages.addingReportingOverflow(compressed)
        let (bytes, bytesOverflow) = all.multipliedReportingOverflow(by: pageSize)
        guard !pagesOverflow, !allOverflow, !bytesOverflow else { return nil }
        return bytes
    }
}
