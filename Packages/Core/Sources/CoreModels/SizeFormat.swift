/// Sizes as the UI shows them.
///
/// Integer arithmetic only, so the text never depends on the locale, and an exact half always rounds up
/// (a `Double` formatter rounds exact binary halves such as 0.25 to even).
public enum SizeFormat {
    /// Finder counts disk space in decimal units.
    private static let gigabyte: UInt64 = 1_000_000_000
    /// Activity Monitor counts memory in binary units, but still labels them MB and GB.
    private static let mebibyte: UInt64 = 1_048_576
    private static let gibibyte: UInt64 = 1_073_741_824

    /// Disk space the way Finder shows it: "15.4 GB".
    /// Below 0.05 GB one decimal would read "0.0", so that range reads "< 0.1 GB".
    public static func disk(_ bytes: Int64) -> String {
        let tenths = rounded(UInt64(clamping: bytes), per: gigabyte, scale: 10)
        return tenths == 0 ? "< 0.1 GB" : gigabytes(tenths: tenths)
    }

    /// Memory the way Activity Monitor shows it: "386 MB", and "2.2 GB" from 1 GB up.
    public static func memory(_ bytes: UInt64) -> String {
        let megabytes = rounded(bytes, per: mebibyte)
        // The unit is picked after rounding, so a byte short of 1 GB reads "1.0 GB", never "1024 MB".
        guard megabytes >= gibibyte / mebibyte else { return "\(megabytes) MB" }
        return gigabytes(tenths: rounded(bytes, per: gibibyte, scale: 10))
    }

    /// `bytes / unit` rounded half up to a multiple of `1 / scale`, returned as that multiple (scale 10 gives tenths).
    /// The whole part is split off before scaling, so the multiplication cannot overflow, even for `UInt64.max`.
    private static func rounded(_ bytes: UInt64, per unit: UInt64, scale: UInt64 = 1) -> UInt64 {
        let (whole, remainder) = bytes.quotientAndRemainder(dividingBy: unit)
        return whole * scale + (remainder * scale + unit / 2) / unit
    }

    private static func gigabytes(tenths: UInt64) -> String {
        "\(tenths / 10).\(tenths % 10) GB"
    }
}
