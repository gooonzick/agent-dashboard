import CoreModels
import Testing

@Suite struct GitModelsTests {
    @Test(arguments: [
        ("claude session test-perf (pid 68374 start Fri Oct 30 14:39:21 2026)", Int32(68374)),
        ("claude session ünï (pid 4242 start Fri Oct 30 14:39:21 2026)", 4242),
        ("pid 7", 7),
        ("(pid 12 start a) (pid 34 start b)", 12),  // the first one
    ])
    func theOwnerIsTheNumberAfterPid(reason: String, owner: Int32) {
        #expect(WorktreeLock(reason: reason) == WorktreeLock(reason: reason, ownerPID: owner))
    }

    @Test(arguments: [
        "",
        "on usb drive",
        "rapid 5",  // pid has to be a word of its own
        "mypid 5",
        "pid5",
        "pid",
        "pid ",
        "pid x",
        "pid -3",
        "pid 0",  // kill(0, ...) is not a process but the whole process group: never an owner
        "pid 99999999999",  // not a process id
    ])
    func aReasonThatNamesNoOwnerHasNone(reason: String) {
        #expect(WorktreeLock(reason: reason).ownerPID == nil)
        #expect(WorktreeLock(reason: reason).reason == reason)
    }

    @Test func anOwnerThatIsGivenIsKept() {
        #expect(WorktreeLock(reason: "on usb drive", ownerPID: 99).ownerPID == 99)
        #expect(WorktreeLock(reason: "claude session x (pid 4242 start y)", ownerPID: nil).ownerPID == nil)
    }
}
