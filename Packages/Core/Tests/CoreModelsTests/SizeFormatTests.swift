import CoreModels
import Testing

@Suite struct SizeFormatTests {
    @Test func disk() {
        #expect(SizeFormat.disk(0) == "< 0.1 GB")
        #expect(SizeFormat.disk(49_999_999) == "< 0.1 GB")
        #expect(SizeFormat.disk(300_000_000) == "0.3 GB")
        #expect(SizeFormat.disk(15_400_000_000) == "15.4 GB")
    }

    @Test func memory() {
        #expect(SizeFormat.memory(404_750_336) == "386 MB")
        #expect(SizeFormat.memory(2_362_232_013) == "2.2 GB")
    }

    // Boundaries the examples above leave open.

    @Test func diskBoundaries() {
        #expect(SizeFormat.disk(50_000_000) == "0.1 GB")  // 0.05 GB is not "less than 0.05 GB"
        #expect(SizeFormat.disk(250_000_000) == "0.3 GB")  // an exact half rounds up, not to even (0.2)
        #expect(SizeFormat.disk(999_950_000) == "1.0 GB")  // rounding carries into the whole part
        #expect(SizeFormat.disk(-1) == "< 0.1 GB")
    }

    @Test func memoryBoundaries() {
        #expect(SizeFormat.memory(0) == "0 MB")
        #expect(SizeFormat.memory(1_072_693_248) == "1023 MB")
        #expect(SizeFormat.memory(1_073_741_823) == "1.0 GB")  // a byte short of 1 GB never reads "1024 MB"
        #expect(SizeFormat.memory(1_073_741_824) == "1.0 GB")
    }
}
