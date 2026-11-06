import Foundation
import Testing

@testable import ProcessKit

@Suite struct SystemMemoryTests {
    @Test func inUseIsBetweenZeroAndThePhysicalMemory() throws {
        let used = try #require(SystemMemory.inUse())

        #expect(used > 0 && used <= ProcessInfo.processInfo.physicalMemory)
    }
}
