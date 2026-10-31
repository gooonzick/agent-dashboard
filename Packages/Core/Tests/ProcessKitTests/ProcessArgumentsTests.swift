import Testing

@testable import ProcessKit

/// How the kernel hands out the arguments of a process (`sysctl KERN_PROCARGS2`): `argc` in the byte order of the host,
/// the path that the program was started from, NULs that pad it, then `argc` arguments and the environment, each string
/// ended by a NUL. The tests build such buffers, whole and cut short, and check what comes out.
@Suite struct ProcessArgumentsTests {
    @Test func readsArgcStringsAfterThePathAndItsPadding() {
        // The kernel pads the path to a multiple of 8 bytes. The reader does not rely on that, and skips every NUL.
        for padding in [0, 1, 6, 7, 15] {
            let layout = Layout(path: "/bin/sleep", padding: padding, arguments: ["/bin/sleep", "30"])
            #expect(layout.parsed == ["/bin/sleep", "30"], "padding \(padding)")
        }
    }

    @Test func theEnvironmentIsNotPartOfThem() {
        let layout = Layout(arguments: ["tool", "-v"], environment: ["HOME=/Users/x", "PATH=/usr/bin"])

        #expect(layout.parsed == ["tool", "-v"])
    }

    @Test func argcSaysHowManyThereAre() {
        // An `argc` of 1 leaves the second string to the environment, which is not looked at.
        #expect(Layout(argc: 1, arguments: ["a", "b"]).parsed == ["a"])
        #expect(Layout(argc: 0, arguments: ["a", "b"]).parsed == [])
        #expect(Layout(argc: -1, arguments: ["a", "b"]).parsed == [])
        #expect(Layout(argc: Int32.min, arguments: ["a"]).parsed == [])
    }

    @Test func anArgcThatIsTooBigGivesTheStringsThatThereAre() {
        #expect(Layout(argc: 5, arguments: ["a", "b"]).parsed == ["a", "b"])
        #expect(Layout(argc: Int32.max, arguments: ["a", "b"]).parsed == ["a", "b"])
    }

    @Test func keepsEmptyAndOddArguments() {
        let arguments = ["tool", "", "a b", "ünï", "日本", "🚀", "--x=\"y\"", " ", "a\nb", "last", ""]

        #expect(Layout(arguments: arguments).parsed == arguments)
    }

    @Test func aBufferThatEndsEarlyGivesTheArgumentsThatAreWhole() {
        let layout = Layout(
            path: "/bin/sh", padding: 0, arguments: ["/bin/sh", "-c", "echo hi", "", "last"], environment: ["HOME=/x"])

        for length in 0...layout.bytes.count {
            // A string whose end is not there is not an argument yet, and one whose end is there is not left out.
            let whole = layout.argumentEnds.filter { $0 <= length }.count
            #expect(
                Kernel.parseArguments(layout.bytes[..<length]) == Array(layout.arguments.prefix(whole)),
                "cut after \(length) of \(layout.bytes.count) bytes")
        }
        #expect(layout.parsed == layout.arguments)
    }

    @Test func aBufferWithoutAnArgcOrWithoutAWholePathGivesNothing() {
        #expect(Kernel.parseArguments([][...]) == [])
        #expect(Kernel.parseArguments([2, 0, 0][...]) == [])
        #expect(Kernel.parseArguments([2, 0, 0, 0][...]) == [])
        #expect(Kernel.parseArguments([2, 0, 0, 0, 0x2F, 0x62][...]) == [])  // a path that has no end
        #expect(Kernel.parseArguments([2, 0, 0, 0, 0x2F, 0][...]) == [])  // a path and nothing behind it
    }

    @Test func textThatIsNotUTF8IsReadAnyway() {
        // A command line is bytes. What cannot be text is replaced, and the other arguments are not lost.
        var layout = Layout(arguments: ["a", "?", "c"])
        let second = layout.argumentEnds[0]  // where the second argument starts
        layout.bytes.replaceSubrange(second..<second + 1, with: [0xFF, 0xFE])

        #expect(layout.parsed == ["a", "\u{FFFD}\u{FFFD}", "c"])
    }

    @Test func bufferOfAnyContentIsReadWithoutTrapping() {
        // What the kernel returns is what the process left on its stack. Whatever is in the buffer, the reader returns.
        var generator = SplitMix64(seed: 0x5EED)
        // Mostly NULs and small numbers, which make `argc`s and short strings: the shapes that matter.
        let alphabet: [UInt8] = [0, 0, 0, 1, 2, 3, 0x61, 0xFF]
        for _ in 0..<5_000 {
            let length = Int(generator.next() % 40)
            let bytes = (0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }

            let parsed = Kernel.parseArguments(bytes[...])

            let argc = bytes.count >= 4 ? bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } : 0
            #expect(parsed.count <= max(Int(argc), 0) && parsed.count <= bytes.count)
        }
    }
}

/// A buffer in the layout of `KERN_PROCARGS2`, and where the arguments end in it.
private struct Layout {
    var bytes: [UInt8]
    /// How many bytes are there when argument `i` is whole: the offset behind its terminating NUL.
    var argumentEnds: [Int] = []
    let arguments: [String]

    /// `path` is followed by its NUL and by `padding` more; `argc` is the number of arguments unless it is given.
    init(
        argc: Int32? = nil, path: String = "/bin/tool", padding: Int = 0, arguments: [String],
        environment: [String] = []
    ) {
        self.arguments = arguments
        bytes = withUnsafeBytes(of: argc ?? Int32(arguments.count)) { Array($0) }
        bytes += Array(path.utf8) + [UInt8](repeating: 0, count: 1 + padding)
        for argument in arguments {
            bytes += Array(argument.utf8) + [0]
            argumentEnds.append(bytes.count)
        }
        for variable in environment { bytes += Array(variable.utf8) + [0] }
    }

    var parsed: [String] { Kernel.parseArguments(bytes[...]) }
}

/// A random number generator with a seed, so that a test that is run twice looks at the same buffers.
private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
