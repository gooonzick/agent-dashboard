import Foundation
import Testing

@testable import ProcessKit

@Suite struct SystemMemoryTests {
    @Test func inUseIsBetweenZeroAndThePhysicalMemory() throws {
        let used = try #require(SystemMemory.inUse())

        #expect(used > 0 && used <= ProcessInfo.processInfo.physicalMemory)
    }

    @Test func theAppsWiredAndCompressedPagesAreInUseLessThePurgeableOnes() {
        let used = SystemMemory.inUse(apps: 100, purgeable: 30, wired: 20, compressed: 10, pageSize: 16_384)

        #expect(used == 100 * 16_384)
    }

    @Test func moreReadPurgeablePagesThanInternalOnesAreNotAnAnswer() {
        // The counters are read one by one; the difference must not trap.
        #expect(SystemMemory.inUse(apps: 10, purgeable: 11, wired: 20, compressed: 10, pageSize: 16_384) == nil)
    }
}
