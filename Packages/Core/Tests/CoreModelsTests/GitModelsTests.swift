import CoreModels
import Testing

@Suite struct GitModelsTests {
    @Test(arguments: [
        ("claude session test-perf (pid 68374 start Fri Oct 30 14:39:21 2026)", Int32(68374)),
        ("claude session ünï (pid 4242 start Fri Oct 30 14:39:21 2026)", 4242),
        ("claude session fix (urgent) (pid 12 start a)", 12),  // a name that has parentheses of its own
        ("claude session x (pid 7 start )", 7),  // whatever stands for the date
        ("claude session x (pid 4242 start …)", 4242),
    ])
    func theOwnerIsTheProcessOfASessionOfClaudeCode(reason: String, owner: Int32) {
        #expect(WorktreeLock(reason: reason) == WorktreeLock(reason: reason, ownerPID: owner))
    }

    @Test(arguments: [
        "",
        "on usb drive",
        "keep until pid 1234 finishes",  // typed by hand: it names a process that is no session of Claude Code
        "pid 7",
        "(pid 12 start a) (pid 34 start b)",
        "rapid 5",
        "mypid 5",
        "pid5",
        "pid",
        "pid x",
        "pid -3",
        "claude session x (pid 0 start y)",  // kill(0, ...) is not a process but the whole process group
        "claude session x (pid 007 start y)",
        "claude session x (pid -3 start y)",
        "claude session x (pid 99999999999 start y)",  // not a process id
        "claude session (pid 12 start y)",  // a session has a name
        "claude session x (pid 12 start y) and more",  // the reason is that and nothing else
        "my claude session x (pid 12 start y)",
        "Claude session x (pid 12 start y)",
        "claude session x (pid 12 started y)",
        "claude session x (pid 12 start y",
        "claude session x (pid 12 start y)\n",
    ])
    func aReasonThatIsNoSessionOfClaudeCodeNamesNoOwner(reason: String) {
        #expect(WorktreeLock(reason: reason).ownerPID == nil)
        #expect(WorktreeLock(reason: reason).reason == reason)
    }

    @Test func anOwnerThatIsGivenIsKept() {
        #expect(WorktreeLock(reason: "on usb drive", ownerPID: 99).ownerPID == 99)
        #expect(WorktreeLock(reason: "claude session x (pid 4242 start y)", ownerPID: nil).ownerPID == nil)
    }
}
