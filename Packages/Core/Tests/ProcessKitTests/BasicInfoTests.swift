import Darwin
import Foundation
import Testing

@testable import ProcessKit

/// What the table of processes says about a process is one structure, with text in character arrays of a fixed size (a
/// name of 31 bytes, and a short one of 15) and the time of the start in two numbers. The tests fill in the structure
/// by hand. A real process cannot be given every one of these names: a copy of a system program that is started from
/// another folder gets killed by the kernel, now and then, for a code signature that is not valid there.
@Suite struct BasicInfoTests {
    @Test func theNameIsTheLongOneWhenThereIsOne() {
        // What a helper app of 30 characters looks like to the kernel: the short name is cut off.
        let info = info(name: "My Long Helper Name (Renderer)", shortName: "My Long Helper ")

        #expect(Kernel.BasicInfo(info).name == "My Long Helper Name (Renderer)")
    }

    @Test func theShortNameStandsInWhenThereIsNoLongOne() {
        #expect(Kernel.BasicInfo(info(name: "", shortName: "tool")).name == "tool")
        #expect(Kernel.BasicInfo(info(name: "", shortName: "")).name == "")
    }

    @Test func aNameThatFillsItsArrayHasNoNULAndIsReadToTheEnd() {
        // 32 and 16 bytes, which is all there is: nothing before the first byte or after the last is read.
        let full = String(repeating: "a", count: 32)
        let shortFull = String(repeating: "b", count: 16)

        #expect(Kernel.BasicInfo(info(name: full, shortName: shortFull)).name == full)
        #expect(Kernel.BasicInfo(info(name: "", shortName: shortFull)).name == shortFull)
    }

    @Test func aNameCutInTheMiddleOfACharacterIsStillText() {
        // The kernel cuts a name after 31 bytes, wherever that is: here, after the first byte of 日.
        let info = info(nameBytes: Array("tool-".utf8) + [0xE6], shortNameBytes: [])

        #expect(Kernel.BasicInfo(info).name == "tool-\u{FFFD}")
    }

    @Test func theStartIsSecondsAndMicroseconds() {
        let info = info(seconds: 1_700_000_000, microseconds: 250_000)

        #expect(Kernel.BasicInfo(info).startDate == Date(timeIntervalSince1970: 1_700_000_000.25))
    }

    @Test func parentAndUserAreTheirOwn() {
        let basic = Kernel.BasicInfo(info(parent: 4321, user: 501))

        #expect(basic.parentID == 4321 && basic.userID == 501)
    }

    private func info(
        name: String = "", shortName: String = "", parent: UInt32 = 1, user: uid_t = 501, seconds: UInt64 = 0,
        microseconds: UInt64 = 0
    ) -> proc_bsdinfo {
        info(
            nameBytes: Array(name.utf8), shortNameBytes: Array(shortName.utf8), parent: parent, user: user,
            seconds: seconds, microseconds: microseconds)
    }

    private func info(
        nameBytes: [UInt8], shortNameBytes: [UInt8], parent: UInt32 = 1, user: uid_t = 501, seconds: UInt64 = 0,
        microseconds: UInt64 = 0
    ) -> proc_bsdinfo {
        var info = proc_bsdinfo()
        fill(&info.pbi_name, with: nameBytes)
        fill(&info.pbi_comm, with: shortNameBytes)
        info.pbi_ppid = parent
        info.pbi_uid = user
        info.pbi_start_tvsec = seconds
        info.pbi_start_tvusec = microseconds
        return info
    }

    /// Copies `bytes` into a character array, which Swift sees as a tuple, as far as the array reaches.
    private func fill<CharacterArray>(_ array: inout CharacterArray, with bytes: [UInt8]) {
        withUnsafeMutableBytes(of: &array) { buffer in
            for (index, byte) in bytes.prefix(buffer.count).enumerated() { buffer[index] = byte }
        }
    }
}
