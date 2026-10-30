# Agent Dashboard — план реализации, часть 1: ядро и экран Projects

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Нативное macOS-приложение, которое находит все git-репозитории и worktree на маке, показывает их статус, статус MR/PR, реальный размер и запущенные в них процессы и безопасно удаляет worktree со смёрженным MR/PR.

**Architecture:** XcodeGen-проект по образцу `~/Development/minuta`: тонкий таргет приложения `App/` и SwiftPM-пакет `Packages/Core` с модулями по доменам. Доменные модули не знают про UI и покрыты Swift Testing; `Dashboard` собирает их в `@Observable`-стор; `AppShell` — SwiftUI-экраны по макетам.

**Tech Stack:** Swift 6.3 (language mode 6, strict concurrency), SwiftUI, macOS 26 SDK, Xcode 26.6, XcodeGen 2.46, Swift Testing; libproc, `getattrlist`, FSEvents, Keychain (Security); CLI: git 2.50, опционально `glab` и `gh`.

**Spec:** `docs/superpowers/specs/2026-10-30-agent-dashboard-design.md` (согласован 2026-10-30). Макеты: `agent-dashboard.pen`, фреймы «Projects — light/dark» и «Remove sheet — light». Файл `.pen` зашифрован: открывать только через Pencil MCP (`get_app_state`, `execute` с `TakeScreenshot`).

**Следующие планы, не в этом документе:** 2 — экран Processes (полоса памяти, таблица процессов, остановка); 3 — экран Caches and Docker; 4 — распространение (Developer ID, нотаризация, Sparkle) и иконка. Пока их нет, пунктов Processes и Caches and Docker в сайдбаре нет.

## Global Constraints

- Deployment target macOS 26.0. Swift language mode 6, `SWIFT_STRICT_CONCURRENCY: complete`, hardened runtime включён, App Sandbox выключен.
- Bundle id `dev.gooonzick.AgentDashboard`, отображаемое имя `Agent Dashboard` (рабочее имя; спека оставляет имя строителю).
- Интерфейс на английском, строки — из раздела «Copy». Шрифт системный, иконки — SF Symbols.
- Ничего не зашито под конкретного пользователя: пути, хосты и учётки берутся из настроек, `git remote` и окружения.
- Только процессы текущего пользователя (`uid == getuid()`).
- Удаление worktree — только `git worktree remove` без `--force`. Никаких `rm -rf` по папкам worktree.
- Worktree с несохранённой работой из приложения не удаляется (Task 10).
- Размер на диске — десятичные гигабайты, как в Finder: «X.X GB»; меньше 0.05 GB → «< 0.1 GB». Память — как в Activity Monitor: «N MB» (1 MB = 1 048 576 байт) до 1024 MB, дальше «X.X GB» (1 GB = 1 073 741 824 байт).
- Процессы опрашиваются раз в 3 с, пока окно видно; когда окно скрыто — пауза.
- Сканы диска и размеров идут в фоне (`.utility` и `.background`) и не блокируют UI. Не больше 4 параллельных git-запросов и 4 сетевых запросов.
- Тесты — Swift Testing (`import Testing`): `swift test --package-path Packages/Core --filter <Suite>`.
- Коммиты — conventional commits: `feat(<module>): …`, `test(<module>): …`, `chore: …`.

## Copy

- Сайдбар: `Projects`, `Ready to remove`, секция `Repositories`, низ: `Macintosh HD`, `<free> free of <total>`.
- Тулбар: заголовок `Projects`, подзаголовок `<N> repositories · <M> worktrees · updated <relative>`; поиск `Search`.
- Блок: заголовок `Ready to remove`, подсказка `MR merged, everything pushed, nothing unsaved · frees <size>`, кнопки `Remove <N>…`, `Remove`, `Stop and remove…`.
- Таблица: заголовок `All projects`, фильтр `All` / `Running` / `Needs attention`, колонки `Name`, `MR / PR`, `State`, `Running`, `Real size`.
- MR/PR: `Open`, `Draft`, `Merged`, `Closed`, `—` (нет или неизвестно).
- State: `Clean`, `<n> changes`, `<n> untracked`, `<n> unpushed`, `Not on remote`, `<n> stashes` (`stash` при n = 1), `Locked`, `Missing`, `Can't verify`.
- Инспектор: `Worktree of <repo>`, кнопки `Terminal`, `Finder`, `Open MR` или `Open PR`; секции `Git` (`Upstream`, `Changes`, `Last commit`, `Merge request` или `Pull request`), `Running` (сумма памяти справа), `Disk` (`<private> frees on removal, of <apparent> on disk`); если private < 25 % от apparent: `Most of this folder is shared with other files (APFS clones), so removing it frees only <private>.`; кнопка `Remove worktree…`.
- Окно подтверждения: заголовок `Remove <N> worktree(s)?`, текст `Their MRs are merged and everything is pushed, so no work will be lost.`, галки `Also delete the local branches` (включена), `Don't ask again for merged, pushed worktrees` (выключена), сноска `Folders are deleted right away, including ignored files like tmp/. Nothing goes to the Trash.`, итог `Frees <size>`, кнопки `Cancel`, `Remove <N> worktree(s)`.
- Первый запуск: `Agent Dashboard looks for git projects on your whole Mac. macOS will ask for access to Desktop, Documents and Downloads — allow it so projects there are found too.`, кнопка `Start scan`.

## Review Focus

1. Ветка со слешем и не-ASCII (`feature/ünï`), путь с пробелом (`My Projects/repo`) → статус читается, MR/PR находится, worktree удаляется. Тесты: Task 4, Task 6, Task 11.
2. Папку worktree удалили руками (`prunable` в `git worktree list`) → строка `Missing` с действием Prune, без падений. Тесты: Task 4, Task 10, Task 12.
3. Detached HEAD (агентские worktree на коммите) → MR/PR не ищется, в Ready to remove не попадает, ручное удаление — только если все коммиты есть на remote. Тесты: Task 4, Task 10.
4. Ошибка хостинга (401, нет сети, 429) → статус MR/PR «неизвестно», в Ready to remove ничего из этого репозитория, ошибка видна в Settings → Accounts. Тесты: Task 6, Task 12.
5. Состояние изменилось между показом в Ready to remove и нажатием Remove (новый файл, новый коммит) → перед удалением всё перечитывается, удаление отменяется с причиной. Тест: Task 11.

## File Structure

```
project.yml                                  XcodeGen: таргет AgentDashboard
App/AgentDashboardApp.swift                  @main, сцены, команды; всё остальное — в AppShell
Packages/Core/Package.swift                  продукты: AppShell (для приложения), остальное — внутренние таргеты
Packages/Core/Sources/CoreModels/            общие типы и SizeFormat
Packages/Core/Sources/Shell/                 CommandRunning, CommandRunner
Packages/Core/Sources/Discovery/             ExclusionRules, RepoScanner
Packages/Core/Sources/GitKit/                GitParsers, GitReader, WorktreeRemover
Packages/Core/Sources/Hosting/               RemoteURL, HostingDetector, TokenStore, TokenImporter, GitLabClient, GitHubClient, ReviewService
Packages/Core/Sources/DiskUsage/             PrivateSizeScanner
Packages/Core/Sources/ProcessKit/            ProcessSampler, ProcessAttributor, ProcessSignaler
Packages/Core/Sources/Safety/                RemovalPolicy
Packages/Core/Sources/Dashboard/             DashboardStore, DashboardCache, FileWatcher, SettingsStore, presenters
Packages/Core/Sources/AppShell/              SwiftUI: RootView, Sidebar, ProjectsView, WorktreeInspector, RemoveSheet, SettingsView, OnboardingView
Packages/Core/Tests/<Module>Tests/           тесты по модулям
```

---

### Task 1: Скелет проекта и форматирование размеров

**Files:**
- Create: `project.yml`, `App/AgentDashboardApp.swift`, `Packages/Core/Package.swift`, `Packages/Core/Sources/CoreModels/SizeFormat.swift`, `Packages/Core/Sources/AppShell/RootView.swift`, `Packages/Core/Tests/CoreModelsTests/SizeFormatTests.swift`, `.gitignore`

**Interfaces:**
- Produces: `public enum SizeFormat { static func disk(_ bytes: Int64) -> String; static func memory(_ bytes: UInt64) -> String }`; продукт `AppShell` с `public struct RootView: View`.

- [ ] **Step 1: Write the failing test**

```swift
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
}
```

- [ ] **Step 2: Run to verify it fails.** Run: `swift test --package-path Packages/Core --filter SizeFormatTests`. Expected: FAIL, `SizeFormat` не определён.
- [ ] **Step 3: Create the package and implement `SizeFormat`.** `Package.swift`: `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, Swift 6 language mode как в minuta; таргеты `CoreModels`, `AppShell` (зависит от `CoreModels`), тест-таргет `CoreModelsTests`. Остальные модули добавляют их задачи.
- [ ] **Step 4: Run to verify it passes.** Same command. Expected: PASS.
- [ ] **Step 5: App target.** `project.yml` по образцу minuta (`packages: Core: path: Packages/Core`, таргет `AgentDashboard`, зависимость от продукта `AppShell`, deployment target 26.0, Swift 6, strict concurrency complete, hardened runtime, Debug подписывается `-`). `App/AgentDashboardApp.swift`: `WindowGroup { RootView() }` с `.defaultSize(width: 1440, height: 900)` и `.frame(minWidth: 900, minHeight: 560)` у `RootView`. `RootView` пока показывает `Text("Projects")`. `.gitignore`: `*.xcodeproj`, `.build/`, `DerivedData/`, `xcuserdata/`, `.DS_Store`.
- [ ] **Step 6: Build.** Run: `xcodegen generate && xcodebuild -project AgentDashboard.xcodeproj -scheme AgentDashboard -destination 'platform=macOS' build`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 7: Commit.** `git init` (если репозитория нет), затем `git add -A && git commit -m "chore: scaffold Agent Dashboard app and core package"`. В коммит попадают спека, план, `agent-dashboard.pen` и всё, что уже лежит в папке.

### Task 2: Запуск CLI

**Files:**
- Create: `Packages/Core/Sources/Shell/CommandRunner.swift`, `Packages/Core/Tests/ShellTests/CommandRunnerTests.swift`
- Modify: `Packages/Core/Package.swift` (таргеты `Shell`, `ShellTests`)

**Interfaces:**
- Produces:

```swift
public struct CommandResult: Sendable, Equatable { public let exitCode: Int32; public let stdout: String; public let stderr: String }
public enum CommandError: Error, Equatable { case notFound(String), timedOut(String) }
public protocol CommandRunning: Sendable {
  func run(_ tool: String, _ args: [String], in directory: URL?, timeout: Duration) async throws -> CommandResult
  func which(_ tool: String) -> URL?
}
public struct CommandRunner: CommandRunning {
  public init(searchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
}
```

Приложение, запущенное из Finder, не получает PATH из шелла, поэтому инструменты ищутся по `searchPaths`, а в окружение дочернего процесса кладётся `PATH` из них же. `tool` может быть абсолютным путём.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct CommandRunnerTests {
  let r = CommandRunner()
  @Test func passesArgumentsWithSpaces() async throws {
    let res = try await r.run("echo", ["a b", "ü"], in: nil, timeout: .seconds(5))
    #expect(res.exitCode == 0 && res.stdout == "a b ü\n")
  }
  @Test func nonZeroExitIsAResultNotAnError() async throws {
    let res = try await r.run("sh", ["-c", "echo oops >&2; exit 3"], in: nil, timeout: .seconds(5))
    #expect(res.exitCode == 3 && res.stderr == "oops\n")
  }
  @Test func timesOut() async {
    await #expect(throws: CommandError.timedOut("sleep")) { try await r.run("sleep", ["5"], in: nil, timeout: .milliseconds(200)) }
  }
  @Test func reportsMissingTool() async {
    await #expect(throws: CommandError.notFound("no-such-tool-xyz")) { try await r.run("no-such-tool-xyz", [], in: nil, timeout: .seconds(1)) }
  }
  @Test func runsInDirectory() async throws {
    let dir = try TempDir(named: "My Projects")
    let res = try await r.run("pwd", [], in: dir.url, timeout: .seconds(5))
    #expect(res.stdout.trimmingCharacters(in: .newlines) == dir.url.resolvingSymlinksInPath().path)
  }
}
```

`TempDir` — хелпер в отдельном таргете `TestSupport` (`Packages/Core/Tests/TestSupport/TempDir.swift`, `.target(name: "TestSupport", path: "Tests/TestSupport")`): создаёт уникальную папку в `FileManager.default.temporaryDirectory` и удаляет её в `deinit`. От `TestSupport` зависят все тест-таргеты; хелперы следующих задач (`spawn`, временные git-репозитории) кладутся туда же.

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter CommandRunnerTests`
- [ ] **Step 3: Implement `CommandRunner`** на `Foundation.Process` с `terminationHandler` и `withCheckedThrowingContinuation`; по таймауту процесс получает `terminate()`, затем бросается `timedOut(tool)`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `git commit -am "feat(shell): add command runner with timeout and explicit PATH"` (новые файлы — через `git add`).

### Task 3: Поиск репозиториев по диску

**Files:**
- Create: `Packages/Core/Sources/Discovery/ExclusionRules.swift`, `Packages/Core/Sources/Discovery/RepoScanner.swift`, `Packages/Core/Tests/DiscoveryTests/RepoScannerTests.swift`
- Modify: `Packages/Core/Package.swift` (таргеты `Discovery`, `DiscoveryTests`)

**Interfaces:**
- Produces:

```swift
public struct ExclusionRules: Sendable, Equatable, Codable {
  public var excludedPaths: [String]          // абсолютные пути без завершающего "/"
  public var includeExternalVolumes: Bool      // по умолчанию false
  public static func defaults(home: URL) -> ExclusionRules
  public static let serviceDirectoryNames: Set<String>
  public func isExcluded(_ path: String) -> Bool   // сам путь или его предок в excludedPaths
}
public protocol RepoScanning: Sendable {
  func scan(roots: [URL], rules: ExclusionRules, isCancelled: @Sendable () -> Bool) async -> [URL]
}
public struct RepoScanner: RepoScanning {
  public init()
  public func defaultRoots(rules: ExclusionRules) -> [URL]     // ["/"] + смонтированные тома, если includeExternalVolumes
  public func scan(roots: [URL], rules: ExclusionRules, isCancelled: @Sendable () -> Bool) async -> [URL]  // корни репозиториев, отсортированы по пути
}
```

Значения из спеки, дословно. `defaults(home:)`: `/System`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/dev`, `/cores`, `/opt/homebrew`, `/Applications`, `/Volumes`, а также `~/Library`, `~/.Trash`, `~/.cargo`, `~/.rustup`, `~/.npm`, `~/.cache`, `~/.bun`, `~/.nvm`, `~/.pnpm-store`, `~/.local/share`, `~/.local/state`, `~/go/pkg`, `~/.gradle`, `~/.m2`, `~/.cocoapods`, `~/.claude/plugins`, `~/.codex`, `~/.vscode/extensions`, `~/.cursor/extensions`, `~/.docker`, `~/.colima`, `~/.lima`, `~/.orbstack`. `serviceDirectoryNames`: `node_modules`, `build`, `.build`, `DerivedData`, `target`, `dist`, `tmp`, `Pods`, `.next`, `.nx`, `.turbo`, `.git`.

Правила обхода: симлинки не открываем; пакеты (`isPackageKey`, например `.app`) не открываем; репозиторий — папка, в которой `.git` является каталогом (файл `.git` у worktree и сабмодулей репозиторием не считается); найдя репозиторий, продолжаем обход его подпапок, но внутри репозитория пропускаем `serviceDirectoryNames`; вне репозитория `tmp` и `build` обходим; нечитаемые папки молча пропускаем; `isCancelled()` проверяем на каждой папке.

- [ ] **Step 1: Write the failing tests** (в `TempDir` строим дерево):

```swift
@Test func findsReposAndSkipsServiceDirsInsideRepos() async throws {
  // a/.git/, b/c/.git/, a/node_modules/x/.git/, a/tmp/protos/.git/, plain/tmp/proj/.git/, wt/.git (файл), Foo.app/Contents/.git/
  let found = await RepoScanner().scan(roots: [tmp.url], rules: .init(excludedPaths: [], includeExternalVolumes: false), isCancelled: { false })
  #expect(found.map(\.lastPathComponent) == ["a", "c", "proj"])
}
@Test func honoursExcludedPaths() async throws   // a исключён → не найден ни a, ни его вложенные
@Test func doesNotFollowSymlinkLoops() async throws   // loop -> .. не зацикливает, a найден один раз
@Test func skipsUnreadableDirectories() async throws  // chmod 000 на папке, скан завершается, соседи найдены
@Test func stopsWhenCancelled() async throws          // isCancelled → true после первой папки, результат пустой или неполный, без зависания
@Test func defaultsExpandHome() { #expect(ExclusionRules.defaults(home: URL(filePath: "/Users/x")).isExcluded("/Users/x/.cargo/registry/foo")) }
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter RepoScannerTests`
- [ ] **Step 3: Implement** через `FileManager.enumerator(at:includingPropertiesForKeys:options:)` с `.skipsPackageDescendants` и ручным `skipDescendants()`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(discovery): scan the disk for git repositories with exclusions`

### Task 4: Чтение git: worktree, статус, stash

**Files:**
- Create: `Packages/Core/Sources/CoreModels/GitModels.swift`, `Packages/Core/Sources/GitKit/GitParsers.swift`, `Packages/Core/Sources/GitKit/GitReader.swift`, `Packages/Core/Tests/GitKitTests/GitParsersTests.swift`, `Packages/Core/Tests/GitKitTests/GitReaderTests.swift`
- Modify: `Packages/Core/Package.swift` (таргеты `GitKit` → `CoreModels`, `Shell`; `GitKitTests`)

**Interfaces:**
- Consumes: `CommandRunning` (Task 2).
- Produces:

```swift
public struct WorktreeLock: Sendable, Equatable, Codable { public let reason: String; public var ownerPID: Int32? }  // ownerPID — число после "pid " в reason
public struct Worktree: Sendable, Equatable, Codable, Identifiable {
  public var id: String { path }
  public let path: String; public let head: String?; public let branch: String?   // branch без "refs/heads/"
  public let isMain: Bool; public let isDetached: Bool; public let lock: WorktreeLock?; public let isPrunable: Bool
}
public struct WorktreeStatus: Sendable, Equatable, Codable {
  public let upstream: String?; public let upstreamGone: Bool; public let ahead: Int; public let behind: Int
  public let modified: Int; public let untracked: Int; public let lastCommitDate: Date?
}
public struct Remote: Sendable, Equatable, Codable { public let name: String; public let url: String }
public enum GitParsers {
  public static func worktrees(porcelain: String) -> [Worktree]          // первая запись — isMain
  public static func status(porcelainV2: String, lastCommit: Date?) -> WorktreeStatus
  public static func stashCount(subjects: String, branch: String) -> Int  // строки `git stash list --format=%gs`
}
public protocol GitReading: Sendable {
  func worktrees(repo: URL) async throws -> [Worktree]
  func status(worktree: URL) async throws -> WorktreeStatus
  func stashCount(repo: URL, branch: String) async throws -> Int
  func remotes(repo: URL) async throws -> [Remote]
  func commitsNotOnAnyRemote(worktree: URL) async throws -> Int                      // git rev-list --count HEAD --not --remotes
  func isAncestorOrEqual(_ commit: String, of other: String, repo: URL) async throws -> Bool?  // nil, если `other` нет локально
  func fetchPrune(repo: URL) async throws
}
public struct GitReader: GitReading { public init(runner: CommandRunning) }
```

Правила разбора: `upstreamGone` = в выводе есть `# branch.upstream`, но нет `# branch.ab`. `modified` — число строк `1 `, `2 `, `u `; `untracked` — строк `? `. Stash относится к ветке, если тема начинается с `WIP on <branch>:` или `On <branch>:`.

- [ ] **Step 1: Write the failing parser tests**

```swift
@Test func parsesWorktreesIncludingClaudeLockPrunableAndDetached() {
  let out = """
  worktree /r/aura
  HEAD 1111
  branch refs/heads/main

  worktree /r/aura/.claude/worktrees/test-perf
  HEAD 2222
  branch refs/heads/test-perf
  locked claude session test-perf (pid 68374 start Fri Oct 30 14:39:21 2026)

  worktree /r/wt-gone
  HEAD 3333
  detached
  prunable gitdir file points to non-existent location

  """
  let w = GitParsers.worktrees(porcelain: out)
  #expect(w.map(\.isMain) == [true, false, false])
  #expect(w[1].lock?.ownerPID == 68374)
  #expect(w[2].isDetached && w[2].isPrunable && w[2].branch == nil)
}
@Test func detectsGoneUpstream() {
  let s = GitParsers.status(porcelainV2: "# branch.oid 1\n# branch.head f\n# branch.upstream origin/f\n", lastCommit: nil)
  #expect(s.upstreamGone && s.ahead == 0)
}
@Test func countsChangesAheadBehind() {
  let s = GitParsers.status(porcelainV2: "# branch.upstream origin/main\n# branch.ab +2 -30\n1 .M N... 1 1 1 a b f.txt\n? new.txt\n? n2.txt\n", lastCommit: nil)
  #expect(s.ahead == 2 && s.behind == 30 && s.modified == 1 && s.untracked == 2 && !s.upstreamGone)
}
@Test func countsStashesOfOneBranch() {
  #expect(GitParsers.stashCount(subjects: "WIP on feature/ünï: 1 x\nOn main: y\nOn feature/ünï: z\n", branch: "feature/ünï") == 2)
}
```

- [ ] **Step 2: Write the failing integration tests** (`GitReaderTests`, настоящий `git` во временной папке `My Projects/`): bare-remote + клон; worktree на ветке `feature/ünï`; незапушенный коммит → `ahead == 1`; push, удаление ветки на remote и `fetchPrune` → `upstreamGone`; новый файл → `untracked == 1`; `git stash` на ветке → `stashCount == 1`; `commitsNotOnAnyRemote` для ветки без upstream с двумя коммитами → 2; `isAncestorOrEqual` для отсутствующего SHA → `nil`; ручное удаление папки worktree → `worktrees(repo:)` отдаёт его с `isPrunable`.
- [ ] **Step 3: Run, expect FAIL.** `swift test --package-path Packages/Core --filter GitKitTests`
- [ ] **Step 4: Implement** парсеры и `GitReader` (`git -C <path> worktree list --porcelain`, `status --porcelain=v2 --branch`, `log -1 --format=%ct`, `stash list --format=%gs`, `remote -v`, `rev-list --count HEAD --not --remotes`, `merge-base --is-ancestor`, `cat-file -e <sha>^{commit}`, `fetch --prune`).
- [ ] **Step 5: Run, expect PASS.**
- [ ] **Step 6: Commit.** `feat(git): read worktrees, status and stashes`

### Task 5: Remote, тип хостинга, токены

**Files:**
- Create: `Packages/Core/Sources/Hosting/RemoteURL.swift`, `HostingDetector.swift`, `TokenStore.swift`, `TokenImporter.swift`; тесты `Packages/Core/Tests/HostingTests/{RemoteURLTests,HostingDetectorTests,TokenStoreTests,TokenImporterTests}.swift`, `Packages/Core/Tests/HostingTests/StubURLProtocol.swift`
- Modify: `Packages/Core/Package.swift` (таргеты `Hosting` → `CoreModels`, `Shell`; `HostingTests`)

**Interfaces:**
- Consumes: `CommandRunning` (Task 2).
- Produces:

```swift
public struct RemoteURL: Sendable, Equatable, Hashable, Codable {
  public let host: String; public let port: Int?; public let projectPath: String   // "group/sub/repo" без ".git"
  public init?(_ raw: String)
}
public enum HostingKind: String, Sendable, Codable { case github, gitlab, unsupported }
public actor HostingDetector {
  public init(overrides: [String: HostingKind], session: URLSession)
  public func kind(for host: String) async -> HostingKind
}
public protocol TokenStoring: Sendable { func token(for host: String) throws -> String?; func setToken(_ token: String?, for host: String) throws }
public struct KeychainTokenStore: TokenStoring { public init(service: String = "dev.gooonzick.AgentDashboard.hosting") }
public struct TokenImporter: Sendable {
  public init(runner: CommandRunning)
  public func importToken(host: String, kind: HostingKind) async -> String?   // glab config get token --host H | gh auth token --hostname H; пустой вывод → nil
}
```

`kind(for:)`: `github.com` → github, `gitlab.com` → gitlab; иначе override; иначе `GET https://<host>/api/v4/version` с ответом 200 или 401 → gitlab; иначе `GET https://<host>/api/v3/meta` с ответом 200 → github; иначе unsupported. Результат запоминается на хост.

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [
  ("git@gitlab.diftech.org:pyme-web/dashboard.git", "gitlab.diftech.org", nil, "pyme-web/dashboard"),
  ("ssh://git@git.example.com:2222/a/b/c.git", "git.example.com", 2222, "a/b/c"),
  ("https://github.com/gooonzick/meetily.git", "github.com", nil, "gooonzick/meetily"),
  ("https://user:pw@gitlab.example.org/team/app", "gitlab.example.org", nil, "team/app"),
])
func parsesRemotes(raw: String, host: String, port: Int?, path: String) {
  let r = RemoteURL(raw)!
  #expect(r.host == host && r.port == port && r.projectPath == path)
}
@Test func rejectsGarbage() { #expect(RemoteURL("not a url") == nil) }
@Test func detectsSelfHostedGitLabBy401() async     // stub: /api/v4/version → 401 → .gitlab
@Test func detectsGitHubEnterpriseByMeta() async   // stub: /api/v4/version → 404, /api/v3/meta → 200 → .github
@Test func overrideWinsAndResultIsMemoized() async  // второй вызов не делает запросов
@Test func keychainRoundTrip() throws              // service "dev.gooonzick.AgentDashboard.tests", запись, чтение, удаление → nil
@Test func importsTokenFromGlab() async            // фейковый CommandRunning отвечает "glpat-xxx\n" на `glab config get token --host h` → "glpat-xxx"
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter HostingTests`
- [ ] **Step 3: Implement.** Keychain — `kSecClassGenericPassword`, account = хост.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(hosting): parse remotes, detect hosting kind, store tokens`

### Task 6: Статус MR и PR

**Files:**
- Create: `Packages/Core/Sources/CoreModels/ReviewModels.swift`, `Packages/Core/Sources/Hosting/GitLabClient.swift`, `GitHubClient.swift`, `ReviewService.swift`; тесты `Packages/Core/Tests/HostingTests/{GitLabClientTests,GitHubClientTests,ReviewServiceTests}.swift` и JSON-фикстуры рядом

**Interfaces:**
- Consumes: `RemoteURL`, `HostingDetector`, `TokenStoring` (Task 5).
- Produces:

```swift
public enum ReviewState: String, Sendable, Codable { case open, draft, merged, closed, none, unknown }
public struct ReviewInfo: Sendable, Equatable, Codable {
  public let state: ReviewState; public let number: Int?; public let webURL: URL?; public let headSHA: String?
  public static let unknown: ReviewInfo; public static let none: ReviewInfo
}
public protocol ReviewProviding: Sendable { func review(remote: RemoteURL, branch: String) async throws -> ReviewInfo }
public struct GitLabClient: ReviewProviding { public init(host: String, token: String?, session: URLSession) }
public struct GitHubClient: ReviewProviding { public init(host: String, token: String?, session: URLSession) }
public protocol ReviewLooking: Sendable {
  func review(remote: RemoteURL, branch: String) async -> ReviewInfo
  func lastError(host: String) async -> String?
  func invalidate() async
}
public actor ReviewService: ReviewLooking {
  public init(detector: HostingDetector, tokens: TokenStoring, session: URLSession, ttl: Duration = .seconds(300))
  public func review(remote: RemoteURL, branch: String) async -> ReviewInfo   // любая ошибка → .unknown и запись в lastError
  public func lastError(host: String) -> String?
  public func invalidate()
}
```

Запросы. GitLab: `GET https://<host>/api/v4/projects/<projectPath, percent-encoded целиком>/merge_requests?source_branch=<branch>&state=all&order_by=updated_at&sort=desc&per_page=1`, заголовок `PRIVATE-TOKEN`. GitHub: API `https://api.github.com` для `github.com`, иначе `https://<host>/api/v3`; `GET <api>/repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=all&sort=updated&direction=desc&per_page=1`, заголовок `Authorization: Bearer <token>`. Значения query кодируются через `URLComponents.queryItems`, слеш в ветке тоже кодируется (`%2F`).

Соответствие состояний. GitLab: `opened` + `draft: true` → draft, `opened` → open, `merged` → merged, `closed`/`locked` → closed; `sha` → headSHA, `iid` → number, `web_url` → webURL. GitHub: `open` + `draft` → draft, `open` → open, `closed` с `merged_at != null` → merged, `closed` → closed; `head.sha`, `number`, `html_url`. Пустой список → `.none`.

- [ ] **Step 1: Write the failing tests** (через `StubURLProtocol`):

```swift
@Test func gitLabMergedMR() async throws {
  stub(json: "gitlab-merged.json")   // [{ "iid": 42, "state": "merged", "draft": false, "sha": "abc", "web_url": "https://g/mr/42" }]
  let r = try await GitLabClient(host: "gitlab.example.org", token: "t", session: stubSession).review(remote: RemoteURL("git@gitlab.example.org:team/app.git")!, branch: "feature/ünï")
  #expect(r.state == .merged && r.headSHA == "abc" && r.number == 42)
  #expect(lastRequest.url!.absoluteString.contains("projects/team%2Fapp/merge_requests"))
  #expect(lastRequest.url!.absoluteString.contains("source_branch=feature%2F%C3%BCn%C3%AF"))
  #expect(lastRequest.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "t")
}
@Test func gitLabDraftAndEmpty() async throws        // draft → .draft; [] → .none
@Test func gitHubMergedClosedDraft() async throws    // три фикстуры → .merged, .closed, .draft; head=gooonzick:feature%2Fx
@Test func gitHubEnterpriseUsesApiV3() async throws  // host ghe.corp → https://ghe.corp/api/v3/repos/...
@Test func serviceTurnsErrorsIntoUnknown() async {   // 401 → .unknown, lastError(host:) содержит "401"
}
@Test func serviceCachesForTTLAndInvalidates() async // два вызова → один запрос; после invalidate() → второй запрос
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter HostingTests`
- [ ] **Step 3: Implement** клиенты на `URLSession.data(for:)` и `Decodable`; `ReviewService` выбирает клиент по `HostingDetector`, берёт токен из `TokenStoring`, для `.unsupported` сразу отдаёт `.unknown`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(hosting): fetch MR and PR status from GitLab and GitHub`

### Task 7: Реальный размер

**Files:**
- Create: `Packages/Core/Sources/CoreModels/SizeInfo.swift`, `Packages/Core/Sources/DiskUsage/PrivateSizeScanner.swift`, `Packages/Core/Tests/DiskUsageTests/PrivateSizeScannerTests.swift`
- Modify: `Packages/Core/Package.swift` (таргеты `DiskUsage`, `DiskUsageTests`)

**Interfaces:**
- Produces:

```swift
public struct SizeInfo: Sendable, Equatable, Codable { public let apparentBytes: Int64; public let privateBytes: Int64; public let computedAt: Date }
public protocol SizeMeasuring: Sendable { func measure(_ root: URL, excluding: Set<String>, isCancelled: @Sendable () -> Bool) throws -> SizeInfo }
public struct PrivateSizeScanner: SizeMeasuring { public init() }
```

Алгоритм из спеки: обход без симлинков, только обычные файлы; `apparent += st_blocks * 512`; `private += ATTR_CMNEXT_PRIVATESIZE` через `getattrlist` с `attrlist(bitmapcount: 5, forkattr: 0x8)` и опциями `FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED (0x20)`, значение — `off_t` по смещению 4 в буфере (проверено на этом маке). Если `getattrlist` не отдал атрибут (не APFS), private = apparent. Файл с `st_nlink > 1` учитывается в apparent один раз на `(st_dev, st_ino)` и даёт 0 в private. Папки из `excluding` (вложенные worktree основного репозитория) пропускаются. Цифры могут занижать освобождаемое место (клоны внутри одной папки), но не завышать — так требует анти-цель «цифры врут».

- [ ] **Step 1: Write the failing tests**

```swift
@Test func plainFileIsPrivate() throws {        // 1 MiB случайных байт → apparent и private в пределах 1 MiB ± 64 KiB
}
@Test func cloneOfOutsideFileFreesNothing() throws {
  // source вне измеряемой папки, clonefile(source, inside/copy, 0)
  let s = try PrivateSizeScanner().measure(inside, excluding: [], isCancelled: { false })
  #expect(s.apparentBytes >= 1 << 20 && s.privateBytes < 64 << 10)
}
@Test func hardLinksCountOnce() throws          // два хардлинка внутри → apparent ≈ 1 MiB, private == 0
@Test func skipsExcludedSubfolders() throws     // вложенный worktree из excluding не учитывается
@Test func stopsWhenCancelled() throws          // бросает CancellationError
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter PrivateSizeScannerTests`
- [ ] **Step 3: Implement** через `fts_open`/`fts_read` или `FileManager.enumerator` + `lstat`; `getattrlist` из `Darwin`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(disk): measure bytes freed on removal via APFS private size`

### Task 8: Снимок процессов

**Files:**
- Create: `Packages/Core/Sources/CoreModels/ProcessModels.swift`, `Packages/Core/Sources/ProcessKit/ProcessSampler.swift`, `Packages/Core/Sources/ProcessKit/ProcessSignaler.swift`, `Packages/Core/Tests/ProcessKitTests/ProcessSamplerTests.swift`
- Modify: `Packages/Core/Package.swift` (таргеты `ProcessKit`, `ProcessKitTests`)

**Interfaces:**
- Produces:

```swift
public struct ProcessRecord: Sendable, Equatable, Codable, Identifiable {
  public var id: Int32 { pid }
  public let pid: Int32; public let ppid: Int32; public let name: String
  public let executablePath: String?; public let arguments: [String]; public let cwd: String?
  public let footprintBytes: UInt64; public let startDate: Date; public let listeningPorts: [UInt16]
}
public protocol ProcessSampling: Sendable { func sample() -> [ProcessRecord] }
public struct ProcessSampler: ProcessSampling { public init(uid: uid_t = getuid()) }
public protocol ProcessSignaling: Sendable { func signal(_ pid: Int32, _ sig: Int32) -> Bool; func isAlive(_ pid: Int32) -> Bool }
public struct ProcessSignaler: ProcessSignaling { public init() }
```

Источники данных: `proc_listallpids`; `proc_pidinfo(PROC_PIDTBSDINFO)` — ppid, uid, время старта, имя; `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — cwd; `proc_pidpath`; `sysctl KERN_PROCARGS2` — аргументы; `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` — память; `PROC_PIDLISTFDS` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` — TCP-сокеты в состоянии `TSI_S_LISTEN`, порт из `insi_lport` в сетевом порядке байт. Процессы, по которым вызовы вернули ошибку (умерли или чужие), пропускаются.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func seesChildWithCwdArgsAndMemory() throws {
  let dir = try TempDir(named: "My Projects")
  let p = try spawn("/bin/sleep", ["30"], cwd: dir.url)   // хелпер на Foundation.Process; убивается в defer
  let rec = try #require(ProcessSampler().sample().first { $0.pid == p.processIdentifier })
  #expect(rec.cwd == dir.url.resolvingSymlinksInPath().path)
  #expect(rec.ppid == getpid() && rec.arguments == ["/bin/sleep", "30"] && rec.footprintBytes > 0)
}
@Test func seesOwnListeningPort() throws {        // socket/bind на 127.0.0.1:0/listen → порт есть в записи getpid()
}
@Test func excludesOtherUsers() { #expect(!ProcessSampler().sample().contains { $0.pid == 1 }) }
@Test func signalerStopsProcess() throws          // SIGTERM → isAlive становится false в течение 2 с
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter ProcessSamplerTests`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(process): sample user processes with cwd, args, memory and ports`

### Task 9: Привязка процессов к worktree и группы

**Files:**
- Create: `Packages/Core/Sources/ProcessKit/ProcessAttributor.swift`, `Packages/Core/Tests/ProcessKitTests/ProcessAttributorTests.swift`, `Packages/Core/Tests/ProcessKitTests/Fixtures.swift`
- Modify: `Packages/Core/Sources/CoreModels/ProcessModels.swift`

**Interfaces:**
- Consumes: `ProcessRecord` (Task 8).
- Produces:

```swift
public enum ProcessKind: String, Sendable, Codable { case agentSession, devServer, daemon, builtHere, shell, other }
public struct ProcessGroup: Sendable, Equatable, Codable, Identifiable {
  public var id: Int32 { leader.pid }
  public let kind: ProcessKind; public let title: String; public let leader: ProcessRecord; public let members: [ProcessRecord]
  public var totalFootprint: UInt64 { get }        // leader + members
  public var ports: [UInt16] { get }
  public func uptime(now: Date) -> TimeInterval
}
public struct ProcessAttributor: Sendable {
  public init(roots: [String])                                         // пути worktree
  public func attribute(_ processes: [ProcessRecord]) -> [String: [ProcessGroup]]   // путь worktree → группы
}
```

Правила, дословно из спеки. Процесс относится к самому глубокому worktree, в котором лежит одно из (по порядку): его cwd; cwd ближайшего предка; путь к исполняемому файлу или любой аргумент. «Лежит в» — сравнение по компонентам пути: `/r/dashboard` не содержит `/r/dashboard-worktrees/x`. Лидер агентской сессии: исполняемый файл содержит `/claude.app/Contents/MacOS/` или его имя `claude`; или имя `codex` без аргумента `app-server`. Участники сессии — все потомки лидера, плюс его родитель, если это `/Claude.app/Contents/Helpers/disclaimer`. Заголовок: `Claude Code · desktop, <N> MCP servers` при наличии `disclaimer`, иначе `Claude Code · CLI, <N> MCP servers`; N — прямые дети лидера, у которых в аргументах есть `mcp` (без учёта регистра); при N = 0 часть `, 0 MCP servers` опускается; для codex — `Codex CLI`. Остальные процессы: каждый процесс, чей родитель не принадлежит тому же worktree, — лидер своей группы вместе с потомками. Вид группы: `devServer`, если кто-то из группы слушает порт; иначе `daemon`, если `leader.ppid == 1`; иначе `builtHere`, если исполняемый файл лидера внутри worktree; иначе `shell`, если имя `zsh`, `bash`, `fish`, `sh` или начинается с `-`; иначе `other`. Заголовок не-агентской группы — имя лидера.

- [ ] **Step 1: Write the failing tests** (фикстуры повторяют разведку 2026-10-30):

```swift
@Test func desktopClaudeSessionIsOneGroup() {
  // Claude.app(cwd /) → disclaimer(cwd W) → claude(cwd W) → 5 детей с "mcp" в аргументах; у chrome-devtools-mcp внук node
  let g = ProcessAttributor(roots: [W]).attribute(fixture.desktopSession)[W]!
  #expect(g.count == 1 && g[0].kind == .agentSession && g[0].title == "Claude Code · desktop, 5 MCP servers")
  #expect(g[0].members.count == 7)   // disclaimer + 5 MCP + node
}
@Test func cliSessionStartedFromShell()            // -zsh → claude → mcp → "Claude Code · CLI, 1 MCP servers"
@Test func builtAppAttributedByExecutablePath()    // cwd "/", exe "<minuta>/build/DerivedData/.../Minuta.app/Contents/MacOS/Minuta" → minuta, .builtHere
@Test func launchdChildIsDaemon()                  // codex app-server, ppid 1, cwd dashboard → .daemon
@Test func deepestRootWinsAndPrefixIsByComponent() // roots /r/dashboard и /r/dashboard-worktrees/PYMEP-1; cwd второго → только второй
@Test func devServerByListeningPort()              // node с портом 4200 и дочерним esbuild → одна группа .devServer, ports == [4200]
@Test func childWithForeignCwdFollowsAncestor()    // cwd "/" у ребёнка процесса из W → в группе W
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter ProcessAttributorTests`
- [ ] **Step 3: Implement** чистыми функциями без системных вызовов.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(process): attribute processes to worktrees and group agent sessions`

### Task 10: Правила безопасного удаления

**Files:**
- Create: `Packages/Core/Sources/Safety/RemovalPolicy.swift`, `Packages/Core/Tests/SafetyTests/RemovalPolicyTests.swift`
- Modify: `Packages/Core/Package.swift` (таргеты `Safety` → `CoreModels`; `SafetyTests`)

**Interfaces:**
- Consumes: `Worktree`, `WorktreeStatus` (Task 4), `ReviewInfo` (Task 6).
- Produces:

```swift
public enum UnsavedReason: Sendable, Equatable, Codable {
  case modified(Int), untracked(Int), stash(Int), unpushed(Int), notOnRemote(Int), commitsAfterMerge, cantVerify, lockedManually, statusUnavailable
}
public enum RemovalEligibility: Sendable, Equatable, Codable {
  case mainWorktree, missing, blocked([UnsavedReason]), ready(needsStopping: Bool), manual(needsStopping: Bool)
}
public struct RemovalFacts: Sendable {
  public let worktree: Worktree; public let status: WorktreeStatus?; public let review: ReviewInfo
  public let stashCount: Int; public let commitsNotOnAnyRemote: Int?; public let headContainedInReview: Bool?
  public let runningGroups: Int; public let lockOwnerAlive: Bool
}
public enum RemovalPolicy { public static func evaluate(_ f: RemovalFacts) -> RemovalEligibility }
```

Таблица решений, по порядку (спека, раздел «Безопасность удаления»):
1. `isMain` → `.mainWorktree`. 2. `isPrunable` → `.missing`. 3. `status == nil` → `.blocked([.statusUnavailable])`.
4. Причины: `modified > 0` → `.modified(n)`; `untracked > 0` → `.untracked(n)`; `stashCount > 0` → `.stash(n)`; блокировка без `ownerPID` → `.lockedManually`.
5. Незапушенное. Есть upstream и он не gone → при `ahead > 0` `.unpushed(ahead)`. Иначе MR/PR `merged` → `headContainedInReview == false` → `.commitsAfterMerge`, `nil` → `.cantVerify`. Иначе → `commitsNotOnAnyRemote > 0` → `.notOnRemote(n)`, `nil` → `.cantVerify`.
6. Причины есть → `.blocked(reasons)` в порядке пунктов 4–5.
7. `needsStopping = runningGroups > 0 || lockOwnerAlive`. Состояние `merged` → `.ready(needsStopping)`, любое другое → `.manual(needsStopping)`.

- [ ] **Step 1: Write the failing tests** (по тесту на строку таблицы; хелпер `facts(...)` с безопасными значениями по умолчанию):

```swift
@Test func mergedCleanIsReady() { #expect(RemovalPolicy.evaluate(facts(review: .merged)) == .ready(needsStopping: false)) }
@Test func mergedCleanWithSessionNeedsStopping() { #expect(RemovalPolicy.evaluate(facts(review: .merged, running: 1)) == .ready(needsStopping: true)) }
@Test func untrackedBlocks() { #expect(RemovalPolicy.evaluate(facts(review: .merged, untracked: 1)) == .blocked([.untracked(1)])) }
@Test func mergedGoneUpstreamHeadMatches() { #expect(RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, contained: true)) == .ready(needsStopping: false)) }
@Test func commitAfterMergeBlocks() { #expect(RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, contained: false)) == .blocked([.commitsAfterMerge])) }
@Test func missingReviewHeadCantVerify() { #expect(RemovalPolicy.evaluate(facts(review: .merged, upstreamGone: true, contained: nil)) == .blocked([.cantVerify])) }
@Test func openMRIsManualOnly() { #expect(RemovalPolicy.evaluate(facts(review: .open)) == .manual(needsStopping: false)) }
@Test func unknownReviewIsManualOnly() { #expect(RemovalPolicy.evaluate(facts(review: .unknown)) == .manual(needsStopping: false)) }
@Test func localOnlyBranchBlocks() { #expect(RemovalPolicy.evaluate(facts(review: .none, upstream: nil, notOnRemote: 3)) == .blocked([.notOnRemote(3)])) }
@Test func detachedPushedIsManual() { #expect(RemovalPolicy.evaluate(facts(branch: nil, detached: true, review: .unknown, upstream: nil, notOnRemote: 0)) == .manual(needsStopping: false)) }
@Test func staleClaudeLockDoesNotBlock() { #expect(RemovalPolicy.evaluate(facts(review: .merged, lock: "claude session x (pid 999999 start …)", lockAlive: false)) == .ready(needsStopping: false)) }
@Test func liveClaudeLockNeedsStopping() { #expect(RemovalPolicy.evaluate(facts(review: .merged, lock: "claude session x (pid 4242 start …)", lockAlive: true)) == .ready(needsStopping: true)) }
@Test func manualLockBlocks() { #expect(RemovalPolicy.evaluate(facts(review: .merged, lock: "on usb drive")) == .blocked([.lockedManually])) }
@Test func mainAndMissing() { /* isMain → .mainWorktree; isPrunable → .missing */ }
@Test func reasonsKeepOrder() { #expect(RemovalPolicy.evaluate(facts(review: .merged, modified: 2, untracked: 1, stash: 1)) == .blocked([.modified(2), .untracked(1), .stash(1)])) }
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter RemovalPolicyTests`
- [ ] **Step 3: Implement** `evaluate` как чистую функцию по таблице.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(safety): decide which worktrees can be removed`

### Task 11: Удаление worktree

**Files:**
- Create: `Packages/Core/Sources/GitKit/WorktreeRemover.swift`, `Packages/Core/Tests/GitKitTests/WorktreeRemoverTests.swift`
- Modify: `Packages/Core/Package.swift` (`GitKit` → `ProcessKit`, `Safety`)

**Interfaces:**
- Consumes: `CommandRunning`, `ProcessGroup`, `ProcessSignaling`, `RemovalEligibility`.
- Produces:

```swift
public struct RemovalRequest: Sendable { public let repo: URL; public let worktree: Worktree; public let deleteBranch: Bool; public let stopGroups: [ProcessGroup] }
public enum RemovalError: Error, Equatable { case stateChanged(RemovalEligibility), gitRefused(String), processStillRunning(Int32) }
public protocol WorktreeRemoving: Sendable {
  func remove(_ r: RemovalRequest, recheck: @Sendable () async -> RemovalEligibility) async throws
  func prune(repo: URL) async throws
}
public struct WorktreeRemover: WorktreeRemoving { public init(runner: CommandRunning, signaler: ProcessSignaling, stopTimeout: Duration = .seconds(5)) }
```

Порядок (спека): 1) SIGTERM всем участникам `stopGroups` от потомков к лидеру, ожидание до `stopTimeout`, затем SIGKILL; кто жив — `processStillRunning`. 2) `recheck()`; если результат не `.ready` и не `.manual` — `stateChanged`, ничего не удаляется. 3) Блокировка с `ownerPID` → `git -C <repo> worktree unlock <path>`. 4) `git -C <repo> worktree remove <path>` без `--force`; ненулевой код → `gitRefused(stderr)`. 5) `deleteBranch && branch != nil` → `git -C <repo> branch -D <branch>`. `prune(repo:)` → `git -C <repo> worktree prune`.

- [ ] **Step 1: Write the failing integration tests** (временные репозитории в папке с пробелом):

```swift
@Test func removesCleanWorktreeWithIgnoredTmpAndNestedRepo() async throws {
  // .gitignore: tmp; в worktree tmp/PYMEP-1/brief.md и tmp/protos/.git (вложенный репозиторий)
  try await remover.remove(.init(repo: repo, worktree: wt, deleteBranch: true, stopGroups: []), recheck: { .ready(needsStopping: false) })
  #expect(!FileManager.default.fileExists(atPath: wt.path))
  #expect(try await git(["branch", "--list", "feature/ünï"], in: repo).stdout.isEmpty)
}
@Test func keepsBranchWhenAsked() async throws
@Test func abortsWhenStateChanged() async throws {
  await #expect(throws: RemovalError.stateChanged(.blocked([.untracked(1)]))) {
    try await remover.remove(req, recheck: { .blocked([.untracked(1)]) })
  }
  #expect(FileManager.default.fileExists(atPath: wt.path))
}
@Test func unlocksStaleClaudeLockAndRemoves() async throws   // git worktree lock --reason "claude session x (pid 999999 start …)"
@Test func stopsProcessesBeforeRemoving() async throws       // sleep с cwd в worktree в stopGroups → после удаления процесс мёртв
@Test func reportsGitRefusal() async throws                   // recheck врёт .ready, но в worktree изменённый файл → gitRefused, папка на месте
@Test func prunesMissingWorktree() async throws               // папку удалили руками → prune → её нет в worktree list
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter WorktreeRemoverTests`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(git): remove worktrees safely with recheck, unlock and stop`

### Task 12: Стор, кеш, наблюдение за файлами, настройки

**Files:**
- Create: `Packages/Core/Sources/Dashboard/{DashboardStore,DashboardEnvironment,DashboardCache,FileWatcher,SettingsStore,Rows}.swift`, `Packages/Core/Tests/DashboardTests/{DashboardStoreTests,SettingsStoreTests,Fakes}.swift`
- Modify: `Packages/Core/Package.swift` (таргет `Dashboard` → все доменные модули; `DashboardTests`)

**Interfaces:**
- Consumes: `RepoScanner`, `GitReading`, `ReviewService`, `SizeMeasuring`, `ProcessSampling`, `ProcessAttributor`, `RemovalPolicy`, `WorktreeRemoving`.
- Produces:

```swift
public struct WorktreeRow: Sendable, Equatable, Identifiable {
  public var id: String { worktree.path }
  public let repoPath: String; public let repoName: String; public let worktree: Worktree; public let status: WorktreeStatus?
  public let review: ReviewInfo; public let hosting: HostingKind?; public let groups: [ProcessGroup]
  public let size: SizeInfo?; public let eligibility: RemovalEligibility
}
public struct ProjectRow: Sendable, Equatable, Identifiable { public var id: String { path }; public let path: String; public let name: String; public let main: WorktreeRow; public let worktrees: [WorktreeRow] }
public enum ScanState: Sendable, Equatable { case idle, scanning(found: Int), failed(String) }
public enum RemovalOutcome: Sendable, Equatable { case removed(String), failed(String, RemovalError) }
public struct DashboardEnvironment: Sendable {   // все зависимости как протоколы, в тестах — фейки
  public var scanner: RepoScanning; public var git: GitReading; public var reviews: ReviewLooking; public var sizes: SizeMeasuring
  public var sampler: ProcessSampling; public var signaler: ProcessSignaling; public var remover: WorktreeRemoving
  public var watcher: FileWatching; public var cache: DashboardCache; public var settings: SettingsStore
  public var now: @Sendable () -> Date
}
@MainActor @Observable public final class DashboardStore {
  public init(env: DashboardEnvironment)
  public private(set) var projects: [ProjectRow]
  public var readyToRemove: [WorktreeRow] { get }        // eligibility == .ready
  public private(set) var scanState: ScanState
  public private(set) var lastUpdated: Date?
  public var isWindowVisible: Bool                        // false → опрос процессов на паузе
  public func start() async                               // кеш → скан → статусы → MR/PR → размеры
  public func refresh() async                             // статусы и процессы, без сети
  public func fetchAll() async                            // git fetch --prune по всем, reviews.invalidate(), refresh, MR/PR
  public func remove(_ rows: [WorktreeRow], deleteBranches: Bool) async -> [RemovalOutcome]
  public func prune(repoPath: String) async
}
public final class SettingsStore: @unchecked Sendable {   // UserDefaults
  public init(defaults: UserDefaults)
  public var rules: ExclusionRules; public var hostingOverrides: [String: HostingKind]
  public var skipConfirmForMergedPushed: Bool; public var didOnboard: Bool; public var hiddenRepos: Set<String>
}
```

`FileWatching` — протокол над FSEvents: `public protocol FileWatching: Sendable { func watch(paths: [String], latency: Duration, onChange: @escaping @Sendable ([String]) -> Void) -> AnyObject }` (возвращает токен, при освобождении которого наблюдение прекращается); реализация `FileWatcher` на `FSEventStreamCreate`. Для каждой строки стор собирает `RemovalFacts`: `headContainedInReview` = `git.isAncestorOrEqual(head, of: review.headSHA)`, только если MR/PR смёржен и есть headSHA; `lockOwnerAlive` — через `ProcessSignaling.isAlive`. `remove` передаёт в `WorktreeRemover` `recheck`, который заново читает статус, stash, MR/PR (с `invalidate()` для этого репозитория) и вызывает `RemovalPolicy`. Кеш — JSON `~/Library/Application Support/AgentDashboard/cache.json`: корни репозиториев и `SizeInfo` по путям. Наблюдение через `FileWatching`, задержка 2 с, два потока: на корни worktree (событие под путём → размер помечается устаревшим, статус этой строки перечитывается) и на корни сканирования (появился или исчез каталог `.git` с родителем вне исключений и служебных папок → репозиторий добавляется или убирается без полного скана; так спека требует ловить новые и удалённые репозитории).

- [ ] **Step 1: Write the failing tests** (фейки всех протоколов в `Fakes.swift`):

```swift
@Test func showsCachedProjectsBeforeScanFinishes() async      // кеш с 2 репозиториями, сканер висит → projects.count == 2
@Test func readyContainsOnlyMergedClean() async               // 3 worktree: merged clean, merged untracked, open clean → readyToRemove == [первый]
@Test func hostingFailureLeavesNothingReady() async           // ReviewService на стабе 401 → все review .unknown, readyToRemove пуст
@Test func samplesProcessesOnlyWhenVisible() async            // isWindowVisible = false → 0 вызовов sample() за 10 с фейкового времени; true → 3+
@Test func removeRechecksAndReportsStateChange() async        // фейковый git после показа отдаёт untracked 1 → .failed(path, .stateChanged(.blocked([.untracked(1)])))
@Test func removeRefreshesTheRepo() async                     // после .removed строки нет в projects
@Test func missingWorktreeCanBePruned() async                 // prunable → eligibility .missing; prune(repoPath:) вызывает remover.prune
@Test func newRepoAppearsFromWatcher() async                  // фейковый watcher шлёт "/x/new/.git" → в projects появляется /x/new без вызова scanner.scan
@Test func deletedRepoDisappearsFromWatcher() async           // событие по "/x/old/.git", папки нет → /x/old пропадает из projects
@Test func settingsRoundTrip() throws                         // UserDefaults(suiteName:) → значения по умолчанию из спеки и сохранение
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter DashboardTests`
- [ ] **Step 3: Implement.** Параллельность: статусы и MR/PR — `TaskGroup` с лимитом 4; размеры — по одному с приоритетом `.background`; опрос процессов — `Task` с `Task.sleep(for: .seconds(3))`, отменяется при `isWindowVisible = false`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit.** `feat(dashboard): orchestrate scan, status, reviews, sizes and processes`

### Task 13: Главное окно: сайдбар, Projects, инспектор

**Files:**
- Create: `Packages/Core/Sources/AppShell/{RootView,SidebarView,ProjectsView,ReadyToRemoveSection,ProjectsTable,WorktreeInspector,Chips}.swift`, `Packages/Core/Sources/Dashboard/RowPresenter.swift`, `Packages/Core/Tests/DashboardTests/RowPresenterTests.swift`
- Modify: `Packages/Core/Package.swift` (`AppShell` → `Dashboard`), `App/AgentDashboardApp.swift`

**Interfaces:**
- Consumes: `DashboardStore`, `WorktreeRow`, `ProjectRow`, `SizeFormat`.
- Produces: `public struct StateChip: Equatable { public let text: String; public let warning: Bool }`, `public enum RowPresenter { static func reviewChip(_ r: ReviewInfo) -> String; static func stateChips(_ row: WorktreeRow) -> [StateChip]; static func runningText(_ groups: [ProcessGroup]) -> String?; static func branchLine(_ s: WorktreeStatus?, branch: String?) -> String; static func diskNote(_ s: SizeInfo) -> String? }`; `public struct RootView: View { public init(store: DashboardStore) }`.

`runningText`: подписи групп без шеллов, по убыванию памяти; сессия Claude Code → `Claude`, Codex → `Codex`, остальные → имя лидера; одинаковые подписи схлопываются в `×N` (`Claude ×2`); через `, `; затем ` · ` и память всех групп, включая шеллы, через `SizeFormat.memory`. Нет групп или только шеллы → `nil` (в таблице `—`). Пример из макета: `Claude ×2, Minuta · 634 MB`.

Макет — `agent-dashboard.pen`, фреймы «Projects — light» и «Projects — dark». `NavigationSplitView`: сайдбар (`Projects` ⌘1, `Ready to remove` ⌘2 с `.badge`, секция `Repositories` — репозитории с числом worktree, внизу свободное место на загрузочном диске из `volumeAvailableCapacityForImportantUsageKey`); деталь — `ProjectsView` (блок Ready to remove, затем `All projects` с фильтром и иерархической таблицей `Table` с `OutlineGroup` или `DisclosureTableRow`); `.inspector` с `WorktreeInspector`. Тулбар: заголовок и подзаголовок из Copy, кнопки Fetch (`arrow.down.circle`) и Refresh (`arrow.clockwise`), `.searchable` по именам, переключатель инспектора. Выбор репозитория в сайдбаре фильтрует таблицу. `Needs attention` — строки с `.blocked` или `.missing`; `Running` — строки с группами. SF Symbols: репозиторий `folder`, worktree `arrow.triangle.branch`, Ready to remove `sparkles`, MR/PR `arrow.triangle.pull`, merged `arrow.triangle.merge`, агентская сессия `sparkle`. Кнопки инспектора: Terminal → `NSWorkspace.open([url], withApplicationAt: Terminal.app)`, Finder → `activateFileViewerSelecting`, Open MR/PR → `review.webURL`.

- [ ] **Step 1: Write the failing presenter tests**

```swift
@Test func reviewChips() { #expect(RowPresenter.reviewChip(.init(state: .merged, ...)) == "Merged"); #expect(RowPresenter.reviewChip(.unknown) == "—") }
@Test func stateChipsFromReasons() {
  #expect(RowPresenter.stateChips(row(.blocked([.modified(11), .stash(1)]))) == [StateChip(text: "11 changes", warning: true), StateChip(text: "stash", warning: true)])
  #expect(RowPresenter.stateChips(row(.ready(needsStopping: false))) == [StateChip(text: "Clean", warning: false)])
  #expect(RowPresenter.stateChips(row(.missing)) == [StateChip(text: "Missing", warning: true)])
  #expect(RowPresenter.stateChips(row(.blocked([.cantVerify]))) == [StateChip(text: "Can't verify", warning: true)])
}
@Test func runningText() {
  #expect(RowPresenter.runningText([claudeGroup(footprint: 404_750_336)]) == "Claude · 386 MB")
  #expect(RowPresenter.runningText([claudeGroup(footprint: 314 << 20), claudeGroup(footprint: 210 << 20), builtHere("Minuta", footprint: 11 << 20), shell(footprint: 99 << 20)]) == "Claude ×2, Minuta · 634 MB")
  #expect(RowPresenter.runningText([shell(footprint: 3 << 20)]) == nil)
}
@Test func branchLine() { #expect(RowPresenter.branchLine(status(ahead: 0, behind: 30), branch: "main") == "main ↓30"); #expect(RowPresenter.branchLine(status(ahead: 69, behind: 0), branch: "main") == "main ↑69") }
@Test func diskNoteOnlyWhenMostlyShared() {
  #expect(RowPresenter.diskNote(.init(apparentBytes: 3_100_000_000, privateBytes: 300_000_000, computedAt: .now)) == "Most of this folder is shared with other files (APFS clones), so removing it frees only 0.3 GB.")
  #expect(RowPresenter.diskNote(.init(apparentBytes: 1_000_000_000, privateBytes: 900_000_000, computedAt: .now)) == nil)
}
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter RowPresenterTests`
- [ ] **Step 3: Implement `RowPresenter`, then the views.**
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Run the app and compare with the mockups.** `xcodegen generate && xcodebuild … build`, запустить `.app`. Сверить со скриншотами фреймов «Projects — light/dark» (Pencil MCP `TakeScreenshot`): сайдбар, блок Ready to remove, таблица, инспектор, тёмная тема. Ожидание: те же разделы, колонки и строки; системный вид вместо Inter и lucide допустим. Затем включить в System Settings → Accessibility → Display «Reduce transparency» и «Increase contrast»: всё читается, сайдбар без прозрачности. Стрелки ↑/↓ ходят по таблице, ←/→ сворачивают и разворачивают репозитории.
- [ ] **Step 6: Commit.** `feat(ui): main window with projects, ready to remove and inspector`

### Task 14: Удаление из интерфейса, меню и контекстные меню

**Files:**
- Create: `Packages/Core/Sources/AppShell/{RemoveSheet,AppCommands,RowContextMenu}.swift`, `Packages/Core/Sources/Dashboard/RemoveSheetModel.swift`, `Packages/Core/Tests/DashboardTests/RemoveSheetModelTests.swift`
- Modify: `App/AgentDashboardApp.swift` (`.commands { AppCommands(...) ; InspectorCommands() }`)

**Interfaces:**
- Consumes: `DashboardStore.remove`, `SettingsStore.skipConfirmForMergedPushed`.
- Produces: `public struct RemoveSheetModel: Equatable { public init(rows: [WorktreeRow]); public var title: String; public var removeButtonTitle: String; public var totalFrees: String; public var needsStopping: Bool }`.

Окно подтверждения — фрейм «Remove sheet — light». Галка `Don't ask again…` пишет `skipConfirmForMergedPushed`; когда флаг стоит, кнопки Remove у строк с `.ready(needsStopping: false)` удаляют без окна; для `needsStopping: true` и для ручного удаления из инспектора окно показывается всегда. Ошибки `RemovalOutcome.failed` показываются одним алертом со списком worktree и причин. Команды меню: `Refresh` ⌘R, `Fetch All` ⇧⌘R, `Remove…` ⌘⌫ (для выделенных строк), `Projects` ⌘1, `Ready to remove` ⌘2; Settings ⌘, — стандартный. Контекстное меню строки: `Remove…`, `Reveal in Finder`, `Open in Terminal`, `Open MR`/`Open PR`, `Copy Path`, `Hide Repository`; для `.missing` — `Prune`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func titlesAndTotal() {
  let m = RemoveSheetModel(rows: [ready(private: 200_000_000), ready(private: 300_000_000), ready(private: 300_000_000)])
  #expect(m.title == "Remove 3 worktrees?" && m.removeButtonTitle == "Remove 3 worktrees" && m.totalFrees == "Frees 0.8 GB")
}
@Test func singular() { #expect(RemoveSheetModel(rows: [ready(private: 0)]).title == "Remove 1 worktree?") }
@Test func needsStoppingWhenAnyRowRuns() { #expect(RemoveSheetModel(rows: [ready(private: 0, needsStopping: true)]).needsStopping) }
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter RemoveSheetModelTests`
- [ ] **Step 3: Implement the model, sheet, commands and context menus.**
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Manual check** на одноразовом репозитории (например, `/tmp/ad-check` с bare remote и смёрженной веткой — без MR-статуса строка будет в `manual`, поэтому проверить удаление из инспектора): окно подтверждения совпадает с макетом, после удаления строки нет, папки нет, ветка удалена.
- [ ] **Step 6: Commit.** `feat(ui): remove sheet, menu commands and context menus`

### Task 15: Настройки и первый запуск

**Files:**
- Create: `Packages/Core/Sources/AppShell/{SettingsView,ScanSettingsView,AccountsSettingsView,OnboardingView}.swift`, `Packages/Core/Sources/Dashboard/AccountsModel.swift`, `Packages/Core/Tests/DashboardTests/AccountsModelTests.swift`
- Modify: `App/AgentDashboardApp.swift` (сцена `Settings { SettingsView(...) }`)

**Interfaces:**
- Consumes: `SettingsStore`, `TokenStoring`, `TokenImporter`, `HostingDetector`, `ReviewLooking.lastError`.
- Produces: `@MainActor @Observable public final class AccountsModel { public init(hosts: [String], settings: SettingsStore, detector: HostingDetector, tokens: TokenStoring, importer: TokenImporter, reviews: ReviewLooking); public private(set) var items: [AccountItem]; public func setToken(_ t: String, host: String); public func importToken(host: String) async; public func setKind(_ k: HostingKind, host: String) }`, `public struct AccountItem: Equatable, Identifiable { host; kind; hasToken; lastError: String? }`.

Settings, вкладка Scan: список исключённых путей (+/−), переключатель `Scan external drives`, кнопка `Rescan now`. Вкладка Accounts: хосты из remote всех репозиториев; у каждого тип (определённый или выбранный вручную), `SecureField` для токена, кнопки `Import from glab` / `Import from gh` (показываются, если инструмент найден через `CommandRunning.which`), последняя ошибка. Первый запуск (`didOnboard == false`): окно с текстом из Copy и кнопкой `Start scan`; скан начинается только после неё.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func listsHostsWithKindsAndTokens() async        // hosts ["github.com", "gitlab.example.org"]; токен есть у второго → hasToken [false, true]
@Test func importStoresTokenAndClearsError() async      // фейковый importer отдаёт "glpat-1" → tokens.token(for:) == "glpat-1"
@Test func manualKindOverridesDetection() async         // setKind(.gitlab, host: "git.corp") → SettingsStore.hostingOverrides["git.corp"] == .gitlab
@Test func showsLastReviewError() async                 // ReviewService со стабом 401 → item.lastError содержит "401"
```

- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter AccountsModelTests`
- [ ] **Step 3: Implement the model and views.**
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Manual check.** Сбросить `didOnboard` (`defaults delete dev.gooonzick.AgentDashboard`), запустить: окно первого запуска, после `Start scan` macOS спрашивает доступ к Desktop/Documents/Downloads; в Accounts есть `gitlab.diftech.org` и `github.com`; `Import from glab` подтягивает токен для `gitlab.diftech.org`.
- [ ] **Step 6: Commit.** `feat(ui): settings for scan and accounts, first-run onboarding`

### Task 16: Проверка на этом маке

**Files:** без изменений кода; заметки — в `docs/superpowers/plans/2026-10-30-agent-dashboard-core.md`, раздел «Результат проверки» в конце.

- [ ] **Step 1: Run all tests.** `swift test --package-path Packages/Core`. Expected: все PASS.
- [ ] **Step 2: Build Release locally.** `xcodebuild -project AgentDashboard.xcodeproj -scheme AgentDashboard -configuration Release -destination 'platform=macOS' build CODE_SIGN_IDENTITY=-`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Check against reality, read only, nothing is removed.** Запустить приложение и сверить с разведкой из спеки: найдены репозитории из `~/Development` (22 на 2026-10-30) и их worktree; у worktree dashboard статусы MR с `gitlab.diftech.org`; Real size у worktree dashboard — десятые доли гигабайта, а не ~3 GB; сессии Claude Code привязаны к своим worktree; `aura/.claude/worktrees/test-perf-stability-audit` показан как Locked; приложение в простое не грузит CPU (Activity Monitor, < 1 % за минуту) и занимает < 150 MB памяти.
- [ ] **Step 4: Record results and commit.** `docs: record verification results for part 1`
