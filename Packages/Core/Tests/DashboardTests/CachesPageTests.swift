import Cleanup
import CoreModels
import Foundation
import Testing

@testable import Dashboard

private let gigabyte: UInt64 = 1_000_000_000
private let home = "/Users/me"

/// A cache in the home of the tests.
private func cache(
    _ id: String, _ group: CacheGroup = .packages, title: String? = nil, paths: [String]? = nil, note: String? = nil,
    action: String = "Clean", cleanable: Bool = true
) -> CacheEntry {
    CacheEntry(
        id: id, group: group, title: title ?? id, paths: paths ?? ["\(home)/Library/Caches/\(id)"], note: note,
        action: action, clean: cleanable ? .deleteContents(of: "\(home)/Library/Caches/\(id)") : nil)
}

private func group(_ pid: Int32, name: String, cwd: String, executable: String? = nil) -> ProcessGroup {
    let leader = ProcessRecord(
        pid: pid, ppid: 1, name: name, executablePath: executable ?? "/usr/bin/\(name)", arguments: [name], cwd: cwd,
        footprintBytes: 1 << 20, startDate: Date(timeIntervalSince1970: 1_800_000_000), listeningPorts: [])
    return ProcessGroup(kind: .devServer, title: name, leader: leader, members: [])
}

/// The page as the state of the store makes it: the numbers on top, the bar, the rows and the Docker card.
@Suite struct CachesPageTests {
    @Test func headlineAndCleanable() {
        let simulators = cache("simulators", .xcode, cleanable: false)
        // pnpm and the simulators have something to clean, but cleaning them does not free what they take.
        let state = CleanupState(
            docker: colima(running: false), caches: [cache("npm"), cache("pnpm"), cache("simulators", .xcode)],
            buildOutputs: [output("target", in: "/x/wt")],
            sizes: [
                CleanupState.dockerDiskKey: 20 * gigabyte, "/x/wt/target": 15 * gigabyte, "npm": 55 * gigabyte,
                "pnpm": 13 * gigabyte, "simulators": 10 * gigabyte,
            ])

        let page = CachesPage(state: state, users: [:], home: home)

        #expect(page.total == 113 * gigabyte)
        #expect(page.cleanable == 70 * gigabyte)
        let headline = CachesPresenter.headline(page)
        #expect(headline.total == "113 GB")
        #expect(headline.detail == "in caches, toolchains and VMs · about 70 GB can be cleaned safely")

        let nothing = CachesPage(
            state: CleanupState(caches: [simulators], sizes: ["simulators": 23 * gigabyte]), users: [:], home: home)
        #expect(CachesPresenter.headline(nothing).total == "23 GB")
        #expect(CachesPresenter.headline(nothing).detail == "in caches, toolchains and VMs")
    }

    @Test func pnpmAndTheSimulatorsAreShownButNotCountedAsCleanable() {
        let state = CleanupState(
            caches: [cache("pnpm", action: "Prune"), cache("simulators", .xcode, action: "Delete Unavailable")],
            sizes: ["pnpm": 13 * gigabyte, "simulators": 10 * gigabyte])

        let page = CachesPage(state: state, users: [:], home: home)

        #expect(page.total == 23 * gigabyte)
        #expect(page.cleanable == 0)
        #expect(CachesPresenter.headline(page).detail == "in caches, toolchains and VMs")
        #expect(page.packages.map(\.size) == [13 * gigabyte])
        #expect(page.packages.map(\.isEnabled) == [true])
        #expect(page.xcode.map(\.size) == [10 * gigabyte])
        #expect(page.xcode.map(\.isEnabled) == [true])
    }

    @Test func smallAmountsKeepATenth() {
        let page = CachesPage(
            state: CleanupState(caches: [cache("npm")], sizes: ["npm": 4_400_000_000]), users: [:], home: home)

        #expect(
            CachesPresenter.headline(page)
                == (total: "4.4 GB", detail: "in caches, toolchains and VMs · about 4.4 GB can be cleaned safely"))
    }

    @Test func whatDockerCanFreeCountsWhenItIsKnown() {
        let state = CleanupState(
            docker: colima(running: true), inventory: someInventory, sizes: [CleanupState.dockerDiskKey: 20 * gigabyte])

        let page = CachesPage(state: state, users: [:], home: home)

        #expect(page.total == 20 * gigabyte)
        // The unused image and the stopped container.
        #expect(page.cleanable == 1_100_000_000 + 2_000)
    }

    @Test func theBarHasTheseCategories() {
        let ids = ["derived-data", "simulators", "pnpm", "pnpm-old", "homebrew", "go", "npm", "playwright", "cocoapods"]
        let tenths: [String: UInt64] = [
            "derived-data": 122, "simulators": 105, "pnpm": 120, "pnpm-old": 18, "homebrew": 49, "go": 57, "npm": 44,
            "playwright": 20, "cocoapods": 10, "/x/a/target": 138, "/x/b/build": 13, CleanupState.dockerDiskKey: 205,
        ]
        let state = CleanupState(
            docker: colima(running: false), caches: ids.map { cache($0) },
            buildOutputs: [output("target", in: "/x/a"), output("build", in: "/x/b")],
            sizes: tenths.mapValues { $0 * gigabyte / 10 })

        let page = CachesPage(state: state, users: [:], home: home)

        #expect(
            page.bar.map(\.label)
                == ["Xcode", "Docker VM", "Build outputs", "pnpm store", "Go", "Homebrew", "npm", "Other"])
        #expect(page.bar.map { $0.bytes * 10 / gigabyte } == [227, 205, 151, 138, 57, 49, 44, 30])
        #expect(page.bar.allSatisfy { $0.worktree == nil })
    }

    @Test func aCategoryWithNothingMeasuredIsLeftOut() {
        let state = CleanupState(caches: [cache("npm"), cache("go")], sizes: ["npm": 2 * gigabyte, "go": 0])

        let page = CachesPage(state: state, users: [:], home: home)

        #expect(page.bar.map(\.label) == ["npm"])
    }

    @Test func aBuildOutputInUseIsNotOffered() {
        let dist = output("dist", in: "/x/wt")
        let target = output("target", in: "/x/wt")
        let build = output("build", in: "/x/wt")
        let state = CleanupState(buildOutputs: [dist, target, build])
        let groups = [
            "/x/wt": [
                group(10, name: "vite", cwd: "/x/wt/dist/assets"),
                group(11, name: "app", cwd: "/", executable: "/x/wt/target/debug/app"),
                // Next to the folder, not in it.
                group(12, name: "node", cwd: "/x/wt/buildkit"),
            ]
        ]

        let users = CachesPage.users(of: state.buildOutputs, in: groups)
        #expect(users == [dist.path: "vite", target.path: "app"])
        let page = CachesPage(state: state, users: users, home: home)
        let rows = Dictionary(uniqueKeysWithValues: page.outputs.map { ($0.id, $0) })

        #expect(rows[dist.path]?.isEnabled == false)
        #expect(rows[dist.path]?.disabledReason == "In use by vite")
        #expect(rows[target.path]?.disabledReason == "In use by app")
        #expect(rows[build.path]?.isEnabled == true)
        #expect(rows[build.path]?.disabledReason == nil)
    }

    @Test func anOutputInUseIsNotCountedAsCleanable() {
        let state = CleanupState(
            buildOutputs: [output("dist", in: "/x/wt"), output("build", in: "/x/wt")],
            sizes: ["/x/wt/dist": 3 * gigabyte, "/x/wt/build": 2 * gigabyte])

        let page = CachesPage(state: state, users: ["/x/wt/dist": "vite"], home: home)

        #expect(page.total == 5 * gigabyte)
        #expect(page.cleanable == 2 * gigabyte)
    }

    @Test func rowsSayWhatTheyAreAndWhatTheyTake() throws {
        let simulators = cache(
            "simulators", .xcode, title: "Simulators", paths: ["\(home)/Library/Developer/CoreSimulator/Devices"],
            action: "Delete Unavailable", cleanable: false)
        let state = CleanupState(
            caches: [
                cache(
                    "pnpm", title: "pnpm store", paths: ["\(home)/Library/pnpm/store/v11"], note: "used by 34 projects",
                    action: "Prune"),
                cache("derived-data", .xcode, title: "DerivedData"), simulators,
                cache("cocoapods", cleanable: false),
            ],
            buildOutputs: [output("build", in: "/x/b"), output("dist", in: "/x/c"), output("target", in: "/x/a")],
            sizes: ["pnpm": 13 * gigabyte, "/x/a/target": 9 * gigabyte, "/x/b/build": 2 * gigabyte],
            working: ["derived-data"])

        let page = CachesPage(state: state, users: [:], home: home)

        // The largest first; one that is not measured yet last.
        #expect(page.outputs.map(\.title) == ["a/target", "b/build", "c/dist"])
        #expect(page.outputs.map(\.subtitle) == ["Rust build", "Rust build", "Rust build"])
        #expect(page.outputs.map(\.size) == [9 * gigabyte, 2 * gigabyte, nil])
        #expect(page.outputs.allSatisfy { $0.action == "Clean" && $0.isEnabled })
        #expect(page.packages.map(\.id) == ["pnpm", "cocoapods"])
        let pnpm = try #require(page.packages.first)
        #expect(pnpm.title == "pnpm store")
        #expect(pnpm.note == "used by 34 projects")
        #expect(pnpm.action == "Prune")
        #expect(pnpm.size == 13 * gigabyte)
        #expect(page.packages[1].isEnabled == false)
        #expect(page.packages[1].disabledReason == "Nothing to delete")
        #expect(page.xcode.map(\.id) == ["derived-data", "simulators"])
        #expect(page.xcode[0].isWorking)
        #expect(!page.xcode[1].isWorking)
        #expect(page.xcode[1].disabledReason == "No unavailable simulators")
    }

    @Test func dockerLines() {
        let full = DockerRuntime(
            kind: .colima, context: "colima", profile: "default", isRunning: false, diskPath: "/vm",
            diskLimit: 100 << 30, cpus: 4, memory: 8 << 30)
        let bare = DockerRuntime(
            kind: .desktop, context: "desktop-linux", profile: nil, isRunning: true, diskPath: "/vm", diskLimit: nil,
            cpus: nil, memory: nil)
        let orbstack = DockerRuntime(
            kind: .orbstack, context: "orbstack", profile: nil, isRunning: true, diskPath: "/vm", diskLimit: nil,
            cpus: nil, memory: nil)
        let work = DockerRuntime(
            kind: .colima, context: "colima-work", profile: "work", isRunning: true, diskPath: "/vm", diskLimit: nil,
            cpus: 2, memory: nil)

        #expect(
            CachesPresenter.dockerLine(full, disk: 20_500_000_000) == "VM disk 20.5 GB of 100 GB · 4 CPU · 8 GB RAM")
        #expect(CachesPresenter.dockerLine(bare, disk: 20_500_000_000) == "VM disk 20.5 GB")
        #expect(CachesPresenter.dockerLine(full, disk: nil) == "VM disk of 100 GB · 4 CPU · 8 GB RAM")
        #expect(CachesPresenter.dockerLine(work, disk: nil) == "VM disk · 2 CPU")
        #expect(CachesPresenter.dockerTitle(full) == "colima · default")
        #expect(CachesPresenter.dockerTitle(work) == "colima · work")
        #expect(CachesPresenter.dockerTitle(bare) == "Docker Desktop")
        #expect(CachesPresenter.dockerTitle(orbstack) == "OrbStack")
    }

    @Test func theDockerCardSaysWhatIsWrong() {
        func section(_ status: DockerStatus?) -> DockerSection {
            CachesPage(state: CleanupState(docker: status), users: [:], home: home).docker
        }

        #expect(section(nil).message == nil)
        #expect(section(nil).runtime == nil)
        #expect(section(.notInstalled).message == "Docker is not installed")
        #expect(section(.unknownContext("rancher")).message == "Unknown Docker context rancher")
        #expect(section(.notAnswering).message == "Docker did not answer")
        #expect(section(colima(running: false)).message == nil)
    }

    @Test func aStoppedVMShowsItsDiskAndCanBeStarted() {
        let state = CleanupState(
            docker: colima(running: false), sizes: [CleanupState.dockerDiskKey: 20_500_000_000],
            working: [CleanupState.startDockerID])

        let docker = CachesPage(state: state, users: [:], home: home).docker

        #expect(docker.title == "colima · default")
        #expect(docker.line == "VM disk 20.5 GB of 100 GB · 4 CPU · 8 GB RAM")
        #expect(docker.diskSize == 20_500_000_000)
        #expect(!docker.isRunning)
        #expect(docker.isStarting)
        #expect(docker.rows.isEmpty)
        #expect(docker.containers.isEmpty)
    }

    @Test func aRunningVMShowsWhatItHolds() throws {
        let state = CleanupState(
            docker: colima(running: true), inventory: someInventory, working: [CleanupState.unusedImagesID])

        let docker = CachesPage(state: state, users: [:], home: home).docker

        #expect(docker.isRunning)
        #expect(!docker.isStarting)
        #expect(docker.rows.map(\.title) == ["Images", "Containers", "Volumes", "Build cache"])
        #expect(docker.rows.map(\.detail) == ["2 images · 1.5 GB", "1 running, 1 stopped", "7.9 GB", "6.0 GB"])
        #expect(docker.rows.map(\.note) == ["1.1 GB unused", nil, nil, nil])
        #expect(docker.rows.map(\.action) == ["Remove Unused…", "Remove Stopped…", nil, nil])
        #expect(
            docker.rows.map(\.id)
                == [CleanupState.unusedImagesID, CleanupState.stoppedContainersID, "volumes", "build-cache"])
        #expect(docker.rows[0].isWorking)
        #expect(docker.rows[0].isEnabled)
        #expect(docker.containers.map(\.name) == ["db", "old"])
        #expect(docker.containers.map(\.project) == ["repo", "—"])
        #expect(docker.unusedImages.map(\.name) == ["node:20"])
        #expect(docker.stoppedContainers.map(\.name) == ["old"])

        let empty = DockerInventory(
            images: [someInventory.images[0]], containers: [], volumesSize: 0, buildCacheSize: 0)
        let clean = CachesPage(
            state: CleanupState(docker: colima(running: true), inventory: empty), users: [:], home: home)
        #expect(
            clean.docker.rows.map(\.detail) == ["1 image · 0.4 GB", "0 running, 0 stopped", "< 0.1 GB", "< 0.1 GB"])
        #expect(clean.docker.rows[0].isEnabled == false)
        #expect(clean.docker.rows[0].disabledReason == "No unused images")
        #expect(clean.docker.rows[1].disabledReason == "No stopped containers")
    }

    @Test func queryFiltersRowsByTitleAndPath() {
        let state = CleanupState(
            caches: [
                cache("homebrew", title: "Homebrew"),
                cache(
                    "go", title: "Go modules and build cache",
                    paths: ["\(home)/go/pkg/mod", "\(home)/Library/Caches/go-build"]),
                cache("derived-data", .xcode, title: "DerivedData"),
            ],
            buildOutputs: [output("target", in: "/x/meetily"), output("dist", in: "/x/web")])

        func ids(_ query: String) -> [String] {
            let page = CachesPage(state: state, users: [:], query: query, home: home)
            return (page.outputs + page.packages + page.xcode).map(\.id)
        }

        #expect(ids("HOMEBREW") == ["homebrew"])
        #expect(ids("go-build") == ["go"])
        #expect(ids("meetily") == ["/x/meetily/target"])
        #expect(ids("  ") == ["/x/meetily/target", "/x/web/dist", "homebrew", "go", "derived-data"])
        #expect(ids("nothing like it").isEmpty)
    }

    @Test func aQueryLeavesTheTotalsAlone() {
        let state = CleanupState(caches: [cache("npm"), cache("go")], sizes: ["npm": 2 * gigabyte, "go": 3 * gigabyte])

        let page = CachesPage(state: state, users: [:], query: "npm", home: home)

        #expect(page.packages.map(\.id) == ["npm"])
        #expect(page.total == 5 * gigabyte)
    }

    @Test func subtitlesUseTilde() {
        let state = CleanupState(caches: [
            cache("homebrew", paths: ["\(home)/Library/Caches/Homebrew"]),
            cache("go", paths: ["\(home)/go/pkg/mod", "\(home)/Library/Caches/go-build"]),
            cache("elsewhere", paths: ["/Users/meow/cache", "/opt/cache"]),
        ])

        let page = CachesPage(state: state, users: [:], home: home)

        #expect(page.packages.map(\.subtitle) == [
            "~/Library/Caches/Homebrew", "~/go/pkg/mod · ~/Library/Caches/go-build", "/Users/meow/cache · /opt/cache",
        ])
    }

    @Test func errorsReadAsSentences() {
        #expect(CachesPresenter.message(for: CleanupError.failed("brew: locked")) == "brew: locked")
        #expect(CachesPresenter.message(for: DockerError(message: "colima: boom")) == "colima: boom")
        #expect(
            CachesPresenter.message(for: CleanupError.notEligible("holds a git repository: build/sub"))
                == "Holds a git repository: build/sub.")
        #expect(
            CachesPresenter.message(for: CleanupError.notEligible("/x/wt/build"))
                == "It can no longer be cleaned safely, so nothing was deleted.")
        #expect(
            CachesPresenter.message(for: CleanupError.notEligible("simulators"))
                == "It can no longer be cleaned safely, so nothing was deleted.")
        #expect(
            CachesPresenter.message(for: CleanupError.pathEscapes("/x/wt/build"))
                == "/x/wt/build leads outside the folder it belongs to, so nothing was deleted.")
    }
}
