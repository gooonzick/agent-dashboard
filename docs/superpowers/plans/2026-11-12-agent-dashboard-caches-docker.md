# Agent Dashboard — план реализации, часть 3: экран Caches and Docker

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** экран Caches and Docker. Он показывает всё тяжёлое вне папок проектов и даёт безопасно это почистить:
- виртуальную машину Docker и то, что в ней лежит;
- сборки внутри проектов;
- кеши пакетных менеджеров;
- Xcode.

**Architecture:** новый модуль `Cleanup` (SwiftPM target), в нём три источника данных:
- `DockerKit.swift`, `DockerInventory.swift`: Docker через `docker`/`colima` CLI;
- `CacheCatalog.swift`: известные кеши по фиксированным путям и командам;
- `BuildOutputs.swift`: папки сборок в worktree, которые уже знает стор.

Сверху над ними лежат:
- `DashboardStore+Cleanup` хранит размеры (кеш на 6 ч, как у worktree), запускает очистку через подтверждение и перемеряет после неё;
- чистая модель `CachesPage`;
- `CachesView` в AppShell.

Все команды запускаются через существующий `CommandRunning` (`Shell`), все размеры считаются через существующий `SizeMeasuring` (`DiskUsage`, приватный размер — столько освободится).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI на macOS 26, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-30-agent-dashboard-design.md`, раздел «Caches and Docker» (строка 68), «Docker» (108–112), «Кеши и сборки» (114–117), «Безопасность удаления».

**Макет:** `docs/superpowers/plans/2026-11-12-caches-docker-mockup.png` (фрейм `NfDdR`, выгружен через OpenPencil MCP). Цифры на макете условные.

**Основа:** `main` на `46a1180`, ветка `feat/caches-docker`.

**Разведка на этом маке (2026-11-12, только чтение):**
- Docker context `colima`: профиль `default` запущен, 4 CPU, 8 GiB, диск 100 GiB. Диск VM на хосте — `~/.colima/_lima/_disks/colima/`, 26 GB.
- В Docker:
  - образы: 18.7 GB, из них освободится 5.4 GB;
  - тома: 7.9 GB, освободится 7.8 GB;
  - кеш сборки: 6.0 GB.
- Кеши:
  - DerivedData — 29 GB;
  - pnpm store — 13 GB. Текущий `v11` занимает только 1.4 GB, остальное — старые `v3` и `v10`, которые `pnpm store prune` не трогает;
  - CoreSimulator — 10 GB, недоступных симуляторов 0;
  - Go: 6.2 GB modcache и 1.6 GB build cache;
  - Homebrew — 5.6 GB;
  - npm — 5.5 GB (`npm` есть только через fnm, `CommandRunner` его не видит);
  - Playwright — 1.5 GB;
  - CocoaPods — 1.0 GB.

## Global Constraints

- **Интерфейс:** на английском. Шрифт системный, иконки SF Symbols, цвета семантические, прозрачность вручную не задаётся.
- **Docker:**
  - берём из текущего docker context: colima, Docker Desktop или OrbStack;
  - для этих рантаймов всегда показываем статус и размер диска VM на хосте, даже когда VM выключена;
  - образы, контейнеры и тома видны, только пока VM запущена. Кнопка «Start and inspect» запускает её;
  - контейнеры привязываем к проектам по метке `com.docker.compose.project.working_dir`;
  - удаляем только неиспользуемые образы и остановленные контейнеры, всегда с подтверждением. Тома и кеш сборки показываем, но не чистим.
- **Кеши:** каждый из известного списка чистится своей безопасной командой (таблица в Task 2), всегда через подтверждение.
- **Сборки внутри проектов:** чистим папку, только если она в `.gitignore` и в ней нет отслеживаемых файлов. Обе проверки повторяются прямо перед удалением.
- **Где удаляем:**
  - удаление — это `FileManager.removeItem`. Решение пользователя: удалять, а не архивировать;
  - удаляются только пути из фиксированного списка или найденные папки сборок;
  - канонический путь (`realpath`) удаляемого обязан лежать внутри ожидаемого корня: кеш — в своём пути, сборка — в своём worktree;
  - симлинк, который ведёт наружу, — отказ.
- **Папка сборки в работе:** если в папке сборки работает процесс (по выборке процессов стора: `cwd` или исполняемый файл внутри), очистку предлагать нельзя. В строке показываем `In use by <name>`.
- **Тесты:**
  - не трогают настоящие кеши, `docker`, `colima`, `brew`, `go`, `pnpm`, `xcrun`, Keychain, сеть и пути вне временной папки;
  - команды проверяются через фейковый `CommandRunning` с записанными JSON-ответами, папки — во временной папке;
  - рендеры только при `AD_RENDER_TESTS=1`.
- **Работа агентов:** приложение не запускать. Не собирать в `/tmp/ad-dd*`. Коммиты в формате Conventional Commits, scope — модуль, без push.

## Review Focus

1. **Docker CLI нет, docker context указывает на что-то неизвестное, `colima` не установлена.** Секция Docker говорит, что не так (`Docker is not installed`, `Unknown Docker context <name>`), а не пустеет и не падает. Тест в Task 1: `anUnknownContextIsNamed`, `noDockerCLI`.
2. **VM запускается долго или не запускается.** «Start and inspect» показывает прогресс, кнопка выключена, пока идёт запуск. Ошибка `colima start` показывается первой строкой stderr. Тест в Task 1: `aFailedStartSaysWhatColimaSaid`.
3. **Кеш удалён или перемещён между замером и очисткой, а путь стал симлинком наружу.** Очистка отказывает и ничего не удаляет. Тест в Task 2: `aCacheThatBecameASymlinkOutsideIsNotCleaned`.
4. **В папке сборки появился отслеживаемый файл или папку убрали из `.gitignore` после замера.** Повторная проверка перед удалением отказывает. Тест в Task 3: `aFolderThatGainedATrackedFileIsNotDeleted`.
5. **Замер DerivedData (десятки GB) идёт долго.** Экран показывает строки сразу. Размер появляется, когда готов, окно не замирает. Замер идёт вне главного актора по одной папке, как размеры worktree. Тест в Task 4: `sizesArriveOneByOne`.

---

### Task 1: Docker — какой рантайм, его статус, диск VM, содержимое и действия

**Files:**
- Modify: `Packages/Core/Package.swift` (target `Cleanup` с зависимостями `CoreModels`, `Shell`, `DiskUsage`; testTarget `CleanupTests` с `Cleanup`, `Shell`, `CoreModels`, `TestSupport` и ресурсами `Fixtures`)
- Create: `Packages/Core/Sources/Cleanup/DockerKit.swift`, `Packages/Core/Sources/Cleanup/DockerInventory.swift`
- Test: `Packages/Core/Tests/CleanupTests/DockerKitTests.swift`, `Packages/Core/Tests/CleanupTests/Fixtures/docker/*.json`

**Interfaces:**
- Produces:
```swift
public enum DockerRuntimeKind: String, Sendable, Equatable { case colima, desktop, orbstack }
public struct DockerRuntime: Sendable, Equatable {
    public let kind: DockerRuntimeKind
    public let context: String          // имя docker context
    public let profile: String?         // профиль colima
    public let isRunning: Bool
    public let diskPath: String?        // файл или папка диска VM на хосте
    public let diskLimit: UInt64?       // выделено (colima: disk), байты
    public let cpus: Int?
    public let memory: UInt64?          // байты
}
public enum DockerStatus: Sendable, Equatable {
    case notInstalled                   // нет `docker` в searchPaths
    case unknownContext(String)         // context есть, но не colima/desktop/orbstack
    case runtime(DockerRuntime)
}
public struct DockerInventory: Sendable, Equatable {
    public let images: [DockerImage]          // id, repository:tag, size, isUnused (не используется ни одним контейнером)
    public let containers: [DockerContainer]  // id, name, image, isRunning, size, project: String? (метка compose working_dir)
    public let volumesSize: UInt64
    public let buildCacheSize: UInt64
}
public protocol DockerControlling: Sendable {
    func status() async -> DockerStatus
    func inventory() async throws -> DockerInventory                  // только при isRunning
    func start(_ runtime: DockerRuntime) async throws                  // colima start <profile> | open -a Docker | orbctl start
    func removeUnusedImages() async throws -> UInt64                   // docker image prune -a -f → reclaimed bytes
    func removeStoppedContainers() async throws -> UInt64              // docker container prune -f
}
public struct DockerController: DockerControlling { public init(runner: any CommandRunning, home: URL) }
public struct DockerError: Error, Equatable { public let message: String }   // первая строка stderr
```

- [ ] **Step 1: Write the failing tests.** Фейковый `CommandRunning` возвращает JSON из `Fixtures/docker/`. Тесты:
  - **Определение рантайма** (`docker context inspect` даёт `Endpoints.docker.Host`):
    - `colimaIsFoundFromTheContextEndpoint`: `unix://<home>/.colima/default/docker.sock` → `.colima`, `profile == "default"`. По `colima list --json` заполняются `isRunning`, `cpus == 4`, `memory == 8 GiB`, `diskLimit == 100 GiB`, а `diskPath == <home>/.colima/_lima/_disks/colima`;
    - `desktopIsFoundFromTheContextEndpoint`: `unix://<home>/.docker/run/docker.sock` → `.desktop`, `diskPath == <home>/Library/Containers/com.docker.docker/Data/vms/0/data`, `isRunning` по успеху `docker info`;
    - `orbstackIsFoundFromTheContextEndpoint`: `unix://<home>/.orbstack/run/docker.sock` → `.orbstack`, `diskPath == <home>/Library/Group Containers/HUAB2SQ2CL.dev.kdrag0n.MacVirt/data`.
  - **Ошибки статуса:**
    - `anUnknownContextIsNamed`: endpoint `tcp://1.2.3.4:2376` → `.unknownContext("remote")`;
    - `noDockerCLI`: `which("docker") == nil` → `.notInstalled`.
  - **Содержимое VM:**
    - `inventoryReadsImagesContainersAndProjects`: `docker image ls -a --format json`, `docker ps -a --format json` (с `--size`), `docker system df --format json`. Контейнер с меткой `com.docker.compose.project.working_dir=/Users/x/Development/minuta` даёт `project == "/Users/x/Development/minuta"`. Образ без контейнеров даёт `isUnused`.
  - **Действия:**
    - `aFailedStartSaysWhatColimaSaid`: `colima start default` выходит с кодом 1 и stderr `FATA[0001] error starting vm\nmore` → `DockerError(message: "FATA[0001] error starting vm")`;
    - `pruneCommandsAreExactlyThese`: фейк записывает аргументы — `["image","prune","-a","-f"]` и `["container","prune","-f"]`, ничего про тома и build cache. Освобождённые байты берутся из строки `Total reclaimed space: 5.393GB`.
  - **Таймауты:**
    - `start`: 180 с;
    - `status` и `inventory`: 15 с;
    - `prune`: 300 с.
- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter DockerKitTests`
- [ ] **Step 3: Implement.**
  - Docker — только через `runner`.
  - Текущий context:
    - имя берётся из `docker context show`, затем `docker context inspect <name>`;
    - context — переменная `DOCKER_CONTEXT` или `docker context show`, без своего разбора `~/.docker/config.json`.
  - Размер диска VM — не здесь (Task 4 меряет `diskPath` через `SizeMeasuring`).
  - Размеры docker (`"5.393GB"`, `"719MB"`, `"24.58kB"`) разбирает функция `DockerSize.bytes(_:) -> UInt64?` с десятичными единицами (kB = 1000). Она покрыта тестом `dockerSizesAreDecimal`.
- [ ] **Step 4: Run, expect PASS**, затем полный набор.
- [ ] **Step 5: Commit.** `feat(cleanup): find the Docker runtime, read what it holds, start it and prune it`

### Task 2: Известные кеши и Xcode

**Files:**
- Create: `Packages/Core/Sources/Cleanup/CacheCatalog.swift`
- Test: `Packages/Core/Tests/CleanupTests/CacheCatalogTests.swift`

**Interfaces:**
- Consumes: `CommandRunning`.
- Produces:
```swift
public enum CacheGroup: String, Sendable { case packages, xcode }
public enum CacheClean: Sendable, Equatable {
    case command(tool: String, args: [String])      // через runner, таймаут 600 с
    case deleteContents(of: String)                 // удалить всё внутри папки, саму папку оставить
    case deleteFolders([String])                    // удалить эти папки целиком
}
public struct CacheEntry: Sendable, Equatable, Identifiable {
    public let id: String            // "pnpm", "pnpm-old", "homebrew", "go", "npm", "playwright", "cocoapods", "derived-data", "simulators"
    public let group: CacheGroup
    public let title: String
    public let paths: [String]       // что мерить (несколько — сумма)
    public let note: String?         // "used by 34 projects", "3 unavailable"
    public let action: String        // заголовок кнопки: "Prune" | "Clean" | "Delete Unavailable"
    public let clean: CacheClean?    // nil — чистить нечего (кнопка выключена, help объясняет)
}
public protocol CacheCataloging: Sendable {
    func entries(projectsUsingPnpm: Int) async -> [CacheEntry]   // только те, чья папка существует
    func clean(_ entry: CacheEntry) async throws                 // повторяет проверку путей, затем чистит
}
public struct CacheCatalog: CacheCataloging { public init(runner: any CommandRunning, home: URL, fileManager: FileManager = .default) }
public enum CleanupError: Error, Equatable { case pathEscapes(String), notEligible(String), failed(String) }
```

- [ ] **Step 1: Write the failing tests.** `home` — временная папка с макетами кешей, `runner` — фейк. Тест `theCatalogIsExactlyThis` проверяет для каждой записи `title`, `paths`, `action` и `clean`:

| id | title | paths | action | clean |
|---|---|---|---|---|
| pnpm | `pnpm store` | вывод `pnpm store path` (например `<home>/Library/pnpm/store/v11`) | `Prune` | `.command("pnpm", ["store","prune"])` |
| pnpm-old | `Old pnpm stores` | соседние папки `v*` рядом с текущей, кроме неё | `Clean` | `.deleteFolders([...])` |
| homebrew | `Homebrew` | `<home>/Library/Caches/Homebrew` | `Clean` | `.command("brew", ["cleanup","--prune=all","-s"])` |
| go | `Go modules and build cache` | `<home>/go/pkg/mod`, `<home>/Library/Caches/go-build` | `Clean` | `.command("go", ["clean","-modcache","-cache"])` |
| npm | `npm` | `<home>/.npm/_cacache` | `Clean` | `.deleteContents(of: "<home>/.npm/_cacache")` |
| playwright | `Playwright browsers` | `<home>/Library/Caches/ms-playwright` | `Clean` | `.deleteContents(of: …)` |
| cocoapods | `CocoaPods` | `<home>/Library/Caches/CocoaPods` | `Clean` | `.deleteContents(of: …)` |
| derived-data | `DerivedData` | `<home>/Library/Developer/Xcode/DerivedData` | `Clean` | `.deleteContents(of: …)` |
| simulators | `Simulators` | `<home>/Library/Developer/CoreSimulator/Devices` | `Delete Unavailable` | `.command("xcrun", ["simctl","delete","unavailable"])`; `nil`, если недоступных 0 |

  Остальные тесты:
  - `onlyWhatExistsIsListed`: кеша нет на диске, или его инструмент не найден (`which == nil`, для записей с `.command`) → записи нет;
  - `theNotesSayWhoUsesItAndWhatIsUnavailable`: у pnpm `note == "used by 34 projects"` при `projectsUsingPnpm: 34` и `nil` при 0. У simulators `note == "2 unavailable"` по `xcrun simctl list devices unavailable -j` (фикстура с двумя устройствами); при 0 — `note == nil` и `clean == nil`;
  - `deleteContentsKeepsTheFolder`: после чистки npm `_cacache` существует и пуст;
  - `aCacheThatBecameASymlinkOutsideIsNotCleaned`: `ms-playwright` подменён симлинком на папку вне `home` → `CleanupError.pathEscapes`, целевая папка цела;
  - `aFailedCommandSaysWhatTheToolSaid`: `brew` вышел с кодом 1 → `.failed(<первая строка stderr>)`.
- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter CacheCatalogTests`
- [ ] **Step 3: Implement.**
  - Перед удалением путь канонизируется и проверяется: внутри `home` и внутри ожидаемого корня записи.
  - `pnpm-old` берёт только имена `v` + цифры, а текущий store не удаляет никогда.
- [ ] **Step 4: Run, expect PASS**, затем полный набор.
- [ ] **Step 5: Commit.** `feat(cleanup): the known caches, what each one takes and how it is cleaned`

### Task 3: Сборки внутри проектов

**Files:**
- Create: `Packages/Core/Sources/Cleanup/BuildOutputs.swift`
- Test: `Packages/Core/Tests/CleanupTests/BuildOutputsTests.swift` (временные репозитории через `GitSandbox` из `TestSupport`)

**Interfaces:**
- Consumes: `CommandRunning` (git), пути worktree от стора.
- Produces:
```swift
public struct BuildOutput: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String          // канонический путь папки
    public let worktree: String      // путь worktree
    public let title: String         // "<имя worktree>/<путь внутри>", например "meetily/target", "dashboard/apps/web/dist"
    public let kind: String          // "Rust build" | "Xcode DerivedData copy" | "Build output" | "Next.js build" | "Swift build" | "Turbo cache"
}
public protocol BuildOutputFinding: Sendable {
    func find(in worktrees: [String]) async -> [BuildOutput]
    func delete(_ output: BuildOutput) async throws      // повторная проверка, затем removeItem
}
public struct BuildOutputFinder: BuildOutputFinding { public init(runner: any CommandRunning) }
```

- [ ] **Step 1: Write the failing tests.**
  - **`candidatesAreTheseNames`.** Ищем папки с именами `target`, `build`, `dist`, `.build`, `.next`, `DerivedData`, `.turbo` на глубине до 4 от корня worktree. Внутрь `node_modules`, `.git` и самих найденных папок не заходим. Тип папки:
    - `target` → `Rust build`;
    - `DerivedData` → `Xcode DerivedData copy`;
    - `.next` → `Next.js build`;
    - `.build` → `Swift build`;
    - `.turbo` → `Turbo cache`;
    - `build` и `dist` → `Build output`.
  - **`onlyIgnoredFoldersWithoutTrackedFilesAreOffered`.** Папку берём, только если `git -C <worktree> check-ignore -q <rel>` вернул 0 и `git -C <worktree> ls-files -- <rel>` пуст. Отсеиваются:
    - отслеживаемый `build/` с файлом в индексе;
    - неигнорируемый `dist/`.
  - **`titleIsWorktreeNameAndRelativePath`.** `meetily/target`, `dashboard/apps/web/dist`.
  - **`aFolderThatGainedATrackedFileIsNotDeleted`.** После `find` в папку добавили файл и сделали `git add -f` → `delete` бросает `CleanupError.notEligible`, папка цела.
  - **`aFolderNoLongerIgnoredIsNotDeleted`.** Из `.gitignore` убрали правило → `.notEligible`.
  - **`aSymlinkedOutputOutsideTheWorktreeIsNotDeleted`.** → `.pathEscapes`.
  - **`deleteRemovesTheFolder`.** Папки больше нет, worktree и остальное на месте.
- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter BuildOutputsTests`
- [ ] **Step 3: Implement.**
  - Обход — `FileManager.enumerator` с пропуском потомков и без перехода по симлинкам.
  - git через `runner` с `--no-optional-locks`, как в части 1.
- [ ] **Step 4: Run, expect PASS**, затем полный набор.
- [ ] **Step 5: Commit.** `feat(cleanup): find build outputs in worktrees that git ignores and holds nothing of`

### Task 4: Стор и модель страницы `CachesPage`

**Files:**
- Modify: `Packages/Core/Package.swift` (`Dashboard` зависит от `Cleanup`), `Dashboard/DashboardEnvironment.swift` (`docker: any DockerControlling`, `caches: any CacheCataloging`, `buildOutputs: any BuildOutputFinding` с живыми значениями в `live()`), `Dashboard/DashboardCache.swift` (размеры кешей по `id` записи и пути сборки, обратно совместимо)
- Create: `Packages/Core/Sources/Dashboard/DashboardStore+Cleanup.swift`, `Packages/Core/Sources/Dashboard/CachesPage.swift`
- Test: `Packages/Core/Tests/DashboardTests/CleanupStoreTests.swift`, `Packages/Core/Tests/DashboardTests/CachesPageTests.swift`

**Interfaces:**
- Consumes: Task 1–3.
- Produces (store):
  - `DashboardStore.cleanup: CleanupState` (observable). Его поля:
    - `docker: DockerStatus?`;
    - `inventory: DockerInventory?`;
    - `caches: [CacheEntry]`;
    - `buildOutputs: [BuildOutput]`;
    - `sizes: [String: UInt64]` — по `CacheEntry.id`, `BuildOutput.path` и ключу `"docker-disk"`;
    - `working: Set<String>` — id строк, которые сейчас чистятся или запускаются;
    - `loadedAt: Date?`.
  - `func loadCleanup(force: Bool = false) async` — при первом открытии экрана и по Refresh.
  - `func startDocker() async -> String?` — сообщение об ошибке или nil.
  - `func clean(cache: CacheEntry) async -> String?`
  - `func clean(output: BuildOutput) async -> String?`
  - `func removeUnusedImages() async -> String?`
  - `func removeStoppedContainers() async -> String?`
- Produces (model):
```swift
public struct CachesPage: Equatable, Sendable {
    public let total: UInt64                 // всё измеренное: диск VM + сборки + кеши
    public let cleanable: UInt64             // сборки, которые можно чистить + кеши с clean != nil + docker reclaimable (если известно)
    public let bar: [MemorySegment]          // переиспользуем тип из ProcessesPage: до 7 категорий + "Other"
    public let docker: DockerSection         // статус, строки содержимого
    public let outputs: [CleanupRow]         // по убыванию размера
    public let packages: [CleanupRow]
    public let xcode: [CleanupRow]
    public init(state: CleanupState, groups: [String: [ProcessGroup]], query: String = "")
}
public struct CleanupRow: Identifiable, Equatable, Sendable {
    public let id: String; public let title: String; public let subtitle: String   // путь с "~" или тип сборки
    public let size: UInt64?; public let note: String?; public let action: String
    public let isEnabled: Bool; public let disabledReason: String?                 // "In use by vite", "Nothing to delete"
}
public enum CachesPresenter {
    public static func headline(_ page: CachesPage) -> (total: String, detail: String)
    // ("113 GB", "in caches, toolchains and VMs · about 70 GB can be cleaned safely")
    public static func dockerLine(_ r: DockerRuntime, disk: UInt64?) -> String
    // "VM disk 20.5 GB of 100 GB · 4 CPU · 8 GB RAM"
    public static func dockerTitle(_ r: DockerRuntime) -> String   // "colima · default" | "Docker Desktop" | "OrbStack"
}
```

- [ ] **Step 1: Write the failing tests.**
  - **Стор, на фейках из Task 1–3:**
    - `sizesArriveOneByOne`: после `loadCleanup()` записи видны сразу, а `sizes` заполняются по одному через фейковый `SizeMeasuring` с `hold`/`release`;
    - `sizesStandSixHours`: повторный `loadCleanup()` через 1 ч не перемеряет, через 7 ч — перемеряет, `force: true` перемеряет всегда;
    - `cleaningRemeasuresThatRowOnly`;
    - `aRowThatIsCleaningIsWorkingUntilItIsDone`;
    - `startDockerReloadsTheStatusAndInventory`;
    - `aFailedCleanReturnsTheMessageAndKeepsTheRow`;
    - `buildOutputsComeFromTheStoresWorktrees` — все `worktreeRoots`;
    - `pnpmNoteCountsRepositoriesWithAPnpmLock` — `pnpm-lock.yaml` в корне репозитория;
    - кеш размеров переживает перезапуск (`DashboardCache`), а старый файл кеша без этих полей грузится.
  - **Модель:**
    - `headlineAndCleanable`: на `total = 113 GB`, `cleanable = 70 GB` даёт `("113 GB", "in caches, toolchains and VMs · about 70 GB can be cleaned safely")`. При `cleanable == 0` вторая часть — `"in caches, toolchains and VMs"`;
    - `theBarHasTheseCategories` — в порядке убывания, с `Other` для остального:
      - `Xcode` = derived-data + simulators;
      - `Docker VM` = docker-disk;
      - `Build outputs`;
      - `pnpm store` = pnpm + pnpm-old;
      - `Homebrew`;
      - `Go`;
      - `npm`;
    - `aBuildOutputInUseIsNotOffered`: процесс с `cwd` внутри папки даёт `isEnabled == false`, `disabledReason == "In use by vite"`;
    - `dockerLines`: `"VM disk 20.5 GB of 100 GB · 4 CPU · 8 GB RAM"`, а без лимита и CPU — `"VM disk 20.5 GB"`. Заголовки — `"colima · default"`, `"Docker Desktop"`, `"OrbStack"`;
    - `queryFiltersRowsByTitleAndPath`;
    - `subtitlesUseTilde`: `<home>/Library/Caches/Homebrew` → `"~/Library/Caches/Homebrew"`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
  - Замеры идут по одному, вне главного актора, через `env.sizes` (тот же паттерн, что `SizeJob`).
  - `cleanup` публикуется отдельным свойством и не трогает `projects` — опрос процессов и размеры worktree не перерисовывают этот экран, и наоборот.
  - После очистки строка перемеряется, а у Docker перечитываются статус и содержимое.
- [ ] **Step 4: Run, expect PASS**, затем полный набор.
- [ ] **Step 5: Commit.** `feat(dashboard): load, measure and clean what the caches page shows`

### Task 5: Экран Caches and Docker

**Files:**
- Create: `Packages/Core/Sources/AppShell/CachesView.swift`, `Packages/Core/Sources/AppShell/CleanupSheet.swift`
- Modify: `AppShell/SidebarView.swift` (`SidebarItem.caches`, `Label("Caches and Docker", systemImage: "cylinder.split.1x2")` после Processes, без бейджа), `AppShell/RootView.swift` (маршрут, заголовок `Caches and Docker`, подзаголовок `Everything heavy that lives outside your project folders`, поиск `Search caches`, Refresh на этом экране вызывает `loadCleanup(force: true)`, при первом показе — `loadCleanup()`), `Tests/AppShellTests/RenderTests.swift`

- [ ] **Step 1: Сверху.**
  - Крупно `total` (`.largeTitle`), рядом `detail` (`.secondary`).
  - Полоса категорий — тот же вид, что «Memory by project» в Processes: 8 pt, промежутки 2 pt, цвета по порядку `.blue, .teal, .indigo, .purple, .orange, .green, .pink`, у Other — `.gray`.
  - Под полосой легенда.
- [ ] **Step 2: Две колонки** — `HStack(alignment: .top)` в `ScrollView`, как на макете.
  - **Слева «Docker»** с подписью `<runtime> runs Docker inside a VM, so images and volumes are only visible while it runs.`. Карточка рантайма:
    - иконка `shippingbox`, `dockerTitle` и капсула статуса `Running` или `Stopped` с точкой;
    - строка `dockerLine`;
    - если VM выключена — кнопка `Start and inspect`. Пока идёт запуск — спиннер и `Starting…`.

    Когда VM запущена, ниже идут строки:
    - `Images` — `N images · X GB`, `Y GB unused`, кнопка `Remove Unused…`;
    - `Containers` — `N running, M stopped`, кнопка `Remove Stopped…`;
    - `Volumes` — размер, без кнопки;
    - `Build cache` — размер, без кнопки;
    - затем список контейнеров: имя, образ и проект (последний компонент `working_dir`) или `—`.

    Состояния `notInstalled` и `unknownContext` показываются одной строкой с объяснением.
  - **Слева ниже «Build outputs in projects»** с подписью `Rebuilt on the next build. Folders with uncommitted work are never touched.`:
    - строки: иконка `folder.badge.gearshape`, `title`, `kind` моноширинным `.caption`, размер и кнопка `Clean`;
    - выключенная строка показывает `disabledReason`;
    - видно 5 строк, дальше `Show all <N>` / `Show less`, как `ReadyListing`.
  - **Справа «Package caches»** с подписью `Safe to clear: packages are downloaded again when needed.`:
    - строки: иконка `shippingbox`, `title`, путь моноширинным `.caption`, капсула `note`, размер и кнопка `action`.
  - **Справа ниже «Xcode»:**
    - строки: иконка `hammer` у DerivedData и `iphone` у Simulators;
    - у Simulators без недоступных кнопка выключена, help: `No unavailable simulators`.
  - Пока размера нет, на его месте небольшой `ProgressView`.
- [ ] **Step 3: Подтверждение** (`CleanupSheet`, sheet по item).
  - Заголовок `Clean <title>?` или `Remove unused images?` / `Remove stopped containers?`.
  - Тело — что именно будет удалено:
    - путь или пути;
    - команда моноширинным шрифтом для `.command`;
    - для Docker — список образов (`repository:tag · size`) или контейнеров (`name · image`).
  - Строка последствия:

    | Что чистится | Строка |
    |---|---|
    | кеши | `Packages are downloaded again when a project needs them.` |
    | сборки | `The next build creates it again.` |
    | DerivedData | `Xcode rebuilds what it needs.` Если Xcode запущен (процесс `Xcode` в выборке) — плюс `Xcode is running; builds in progress may fail.` |
    | Docker | `Images are pulled again when a container needs them.` |
  - Кнопки: деструктивная `Clean` / `Remove`, затем `Cancel`.
  - Ошибка показывается алертом `Could not clean <title>` с сообщением стора.
- [ ] **Step 4: Рендеры** `cachesLight` и `cachesDark` за `AD_RENDER_TESTS=1` на фикстуре по макету: colima остановлена; 2 сборки; 6 кешей; Xcode. Сравнить с `docs/superpowers/plans/2026-11-12-caches-docker-mockup.png` и перечислить в отчёте отличия.
- [ ] **Step 5: Run.** Полный набор и Release-сборка в новый `mktemp -d`.
- [ ] **Step 6: Commit.** `feat(appshell): caches and docker page`

### Task 6: Проверка на этом маке

- [ ] **Step 1: Сборка.** Контроллер собирает Release в новую папку `/tmp/ad-ddN`.
- [ ] **Step 2: Пользователь проверяет руками.**
  - Размеры и состояние colima совпадают с разведкой выше: ±10 %.
  - `Start and inspect` на остановленной VM.
  - Содержимое Docker и проекты контейнеров.
  - Очистка одного небольшого кеша (CocoaPods или Playwright) с подтверждением; размер после неё ≈ 0.
  - Очистка одной папки сборки в проекте, который пользователь выберет сам.
  - Удаление неиспользуемых образов — только если пользователь захочет.
  - Тёмная тема.
- [ ] **Step 3: Простой.** CPU при открытом экране, окно позади другого приложения: < 1 %.
- [ ] **Step 4: Записать и закоммитить.** Раздел «Результат проверки», коммит `docs: record verification results for part 3`.
