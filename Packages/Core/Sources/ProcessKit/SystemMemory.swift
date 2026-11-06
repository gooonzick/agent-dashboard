import Darwin

/// How much of the memory of the Mac is in use.
public enum SystemMemory {
    /// The bytes that Activity Monitor calls "Memory Used": the pages of apps (the internal ones, less those that the
    /// system may purge), the wired ones and those that the compressor holds. The cached files and the free pages are
    /// not in it, for the system gives them up as soon as something asks for the room. `nil` if the system does not
    /// answer.
    public static func inUse() -> UInt64? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard status == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        // A purgeable page is one of the internal ones.
        let pages = UInt64(statistics.internal_page_count) - UInt64(statistics.purgeable_count)
            + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)
        return pages * UInt64(pageSize)
    }
}
