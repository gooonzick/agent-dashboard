# Agent Dashboard — план реализации, часть 2: экран Processes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Экран Processes. На нём видно всё, что запущено в проектах: полоса памяти по проектам и таблица процессов, сгруппированных по worktree. Отсюда же процессы останавливаются.

**Architecture:**
- Данные уже есть в сторе: у каждой строки `WorktreeRow.groups`. Они обновляются раз в 3 с, пока приложение впереди, и раз в 15 с, пока оно позади.
- Новая чистая модель `ProcessesPage` в Dashboard собирает из `[ProjectRow]` секции, строки, полосу памяти и подписи. Новое поле стора: сколько памяти занято на маке и когда был последний опрос.
- Экран `ProcessesView` в AppShell повторяет устройство `ProjectsTable`: `Table` с раскрывающимися строками.
- Остановка, подтверждение и инспектор уже есть, экран их переиспользует: `requestStop`, `StopConfirmation`, `WorktreeInspector`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI на macOS 26, Swift Testing, Mach `host_statistics64`.

**Spec:** `docs/superpowers/specs/2026-10-30-agent-dashboard-design.md`, разделы «Processes» (строка 66) и «Процессы» (99–106).
**Макет:** `docs/superpowers/plans/2026-11-06-processes-mockup.webp`, фрейм «Processes — light» (`rXArj`). Цифры на макете условные.
**Основа:** `main` на `43958bf`. Ветка `feat/processes`.

## Global Constraints

- Интерфейс на английском. Шрифт и иконки системные (SF Symbols), не Inter и не lucide.
- Цвета семантические. Прозрачность нигде не задаётся вручную (Ruling 67).
- Только процессы текущего пользователя.
- Память считается как в Activity Monitor (`phys_footprint`), порты — слушающие TCP.
- Опрос идёт раз в несколько секунд, пока окно видно; пока окно скрыто, опроса нет. Уже сделано, не менять.
- Действия: остановить процесс, сессию целиком или всё в проекте. Перед любой остановкой показывается подтверждение со списком каждого процесса в виде `name · pid N` (Ruling 39). Остановка идёт через `DashboardStore.stop(_:of:)`.
- Сессии агентов, которые работают дольше суток, подсвечены.
- Тесты не трогают настоящий Keychain, `glab`/`gh`, сеть, пути вне временной папки и чужие процессы.
- Рендер-тесты запускаются только с `AD_RENDER_TESTS=1` (Ruling 52).
- Приложение не запускать. Не собирать в `/tmp/ad-dd*`, там лежит запущенная сборка пользователя.
- Коммиты в формате Conventional Commits, scope — модуль. Без push.

## Review Focus

1. **Процесс завершился, пока открыт диалог или выбрана строка.** Строка исчезает при следующем опросе, выбор worktree остаётся, подтверждение по устаревшему снимку ничего чужого не сигналит. Тест в Task 2: `aGroupThatIsGoneLeavesTheSection`.
2. **Много worktree с процессами (20+) и длинные имена.** Полоса показывает 5 самых тяжёлых и «other», подписи легенды не переносятся. Тест в Task 2: `theBarShowsFiveAndOther`.
3. **Процесс без памяти или без портов.** `footprintBytes == 0` (сэмплер не прочитал) показывается как `0 MB`, а не ломает сумму; без порта стоит `—`. Тест в Task 2: `aProcessWithoutMemoryOrPorts`.
4. **Поиск, который ничего не нашёл, и проекты, где ничего не запущено.** Оба случая показывают пустое состояние, а не пустую таблицу. Тест в Task 2: `aQueryThatMatchesNothingLeavesNoSection`, плюс пустое состояние в Task 3.
5. **Часы ядра и часы приложения расходятся.** Время работы не бывает отрицательным: `uptime(now:)` уже ограничивает его нулём. Тест в Task 2: `uptimeIsNeverNegative`.

---

### Task 1: Сколько памяти занято на маке, и когда был опрос

**Files:**
- Create: `Packages/Core/Sources/ProcessKit/SystemMemory.swift`
- Modify: `Packages/Core/Sources/Dashboard/DashboardEnvironment.swift`, `DashboardStore.swift` (`sampleProcesses`)
- Test: `Packages/Core/Tests/ProcessKitTests/SystemMemoryTests.swift`, `Packages/Core/Tests/DashboardTests/ProcessesTests.swift`

**Interfaces:**
- Produces:
  - `public enum SystemMemory { public static func inUse() -> UInt64? }`;
  - `DashboardEnvironment.systemMemory: @Sendable () -> UInt64?` с дефолтом `SystemMemory.inUse`, полем с начальным значением, как `stopTimeout`;
  - `DashboardStore.memoryInUse: UInt64?` (observable);
  - `DashboardStore.processesSampledAt: Date?` (observable).

- [ ] **Step 1: Write the failing tests.**
  - `SystemMemoryTests.inUseIsBetweenZeroAndThePhysicalMemory`: `let used = try #require(SystemMemory.inUse())`, затем `#expect(used > 0 && used <= ProcessInfo.processInfo.physicalMemory)`.
  - `ProcessesTests.eachSampleNotesTheTimeAndTheMemoryInUse`:
    - `Scene` с `env.systemMemory = { 8 << 30 }`;
    - после `await store.sampleProcesses()` должно быть `store.processesSampledAt == scene.now` и `store.memoryInUse == 8 << 30`;
    - второй опрос с той же выборкой после `scene.passTime(3)` двигает `processesSampledAt`, но `projects` не публикуются (Ruling 76).
- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter "SystemMemoryTests|ProcessesTests"`
- [ ] **Step 3: Implement.**
  - `inUse()` — «Memory Used» Activity Monitor: `(internal_page_count − purgeable_count + wire_count + compressor_page_count) × vm_kernel_page_size` из `host_statistics64(mach_host_self(), HOST_VM_INFO64, …)`. Если вызов не `KERN_SUCCESS`, возвращать `nil`.
  - `sampleProcesses` записывает `processesSampledAt = env.now()` и `memoryInUse = env.systemMemory()` при каждом опросе, до проверки «изменилось ли». Системный вызов делать вне главного актора: внутри уже существующего `@concurrent` `ProcessGroups.sample` или рядом с ним.
- [ ] **Step 4: Run, expect PASS.** Затем полный `swift test --package-path Packages/Core`.
- [ ] **Step 5: Commit.** `feat(processkit): read the memory in use on the Mac with each sample of processes`

### Task 2: Модель экрана `ProcessesPage`

**Files:**
- Create: `Packages/Core/Sources/Dashboard/ProcessesPage.swift`
- Test: `Packages/Core/Tests/DashboardTests/ProcessesPageTests.swift`

**Interfaces:**
- Consumes: `ProjectRow`, `WorktreeRow` (`id`, `repoName`, `worktree.isMain`, `groups`), `ProcessGroup` (`kind`, `title`, `leader`, `members`, `totalFootprint`, `ports`, `uptime(now:)`), `SizeFormat.memory`.
- Produces:
```swift
public struct ProcessesPage: Equatable, Sendable {
    public let sections: [ProcessSection]   // по убыванию памяти; при равенстве — по title
    public let processCount: Int            // лидеры и участники всех групп, каждый pid один раз
    public let totalMemory: UInt64
    public let bar: [MemorySegment]         // ≤ 5 worktree и, если их больше, один «other»
    public init(projects: [ProjectRow], query: String = "")
}
public struct ProcessSection: Identifiable, Equatable, Sendable {
    public var id: String { row.id }        // путь worktree
    public let row: WorktreeRow
    public let title: String                // main → имя репозитория; иначе имя папки worktree
    public let subtitle: String             // "12 processes" | "dashboard · 9 processes" | "1 process"
    public let memory: UInt64
    public let lines: [ProcessLine]
}
public struct ProcessLine: Identifiable, Equatable, Sendable {
    public let id: String                   // "<worktree>#<leader pid>" | "<worktree>#rest"
    public let groups: [ProcessGroup]       // одна группа или несколько слитых
    public let title: String
    public let kind: String                 // "Agent session" | "Dev server" | "Daemon" | "Built here" | "Shell" | "Other"
    public let symbol: String               // SF Symbol
    public let pid: Int32?                  // nil у слитой строки
    public let ports: [UInt16]
    public let memory: UInt64
    public func uptime(now: Date) -> Uptime? // nil у слитой строки
}
public struct Uptime: Equatable, Sendable { public let text: String; public let isLong: Bool }
public struct MemorySegment: Equatable, Sendable { public let label: String; public let bytes: UInt64; public let worktree: String? } // nil = other
public enum ProcessesPresenter {
    public static func subtitle(_ page: ProcessesPage, updated: Date?, now: Date) -> String
    public static func inUse(_ page: ProcessesPage, of used: UInt64?) -> String?
    public static func uptime(_ seconds: TimeInterval, kind: ProcessKind) -> Uptime
}
```

- [ ] **Step 1: Write the failing tests** (имена тестов и точные значения):
  - **`sectionsAreWorktreesWithSomethingRunningByMemory`.** Worktree без групп в секции не попадают. Порядок по убыванию `memory`. У main `title == repoName` и `subtitle == "12 processes"`. У linked `title` — последний компонент пути, `subtitle == "dashboard · 9 processes"`. Для одного процесса — `"1 process"`.
  - **`linesAreGroupsByMemoryWithShellsAndHelpersLast`.** Две и больше групп `.shell`/`.other` в одном worktree сливаются в одну последнюю строку:
    - заголовок `"4 shells"`, если все `.shell`, вид `Shell`;
    - `"2 helpers"`, если все `.other`, вид `Other`;
    - `"3 shells, 2 helpers"`, если смешано, вид `Other`;
    - у слитой строки `pid == nil` и `uptime(now:) == nil`, `memory` — сумма, `groups` — все слитые.

    Одна такая группа остаётся обычной строкой со своим `title`.
  - **`kindLabelsAndSymbols`:**

    | kind | label | symbol |
    |---|---|---|
    | agentSession | `Agent session` | `sparkle` |
    | devServer | `Dev server` | `globe` |
    | daemon | `Daemon` | `gearshape` |
    | builtHere | `Built here` | `macwindow` |
    | shell | `Shell` | `apple.terminal` |
    | other | `Other` | `ellipsis` |
  - **`uptimeTexts`:**
    - 30 с → `"<1m"`;
    - 18 мин → `"18m"`;
    - 1 ч 12 мин → `"1h 12m"`;
    - 23 ч 56 мин → `"23h 56m"`;
    - 15 дней `.daemon` → `"15d"`, `isLong == false`;
    - 6 д 22 ч `.agentSession` → `"6d 22h"`, `isLong == true`;
    - ровно 24 ч `.agentSession` → `"1d 0h"`, `isLong == true`;
    - 23 ч 59 мин `.agentSession` → `isLong == false`.
  - **`uptimeIsNeverNegative`:** `startDate` на 5 с позже `now` даёт `"<1m"`.
  - **`theBarShowsFiveAndOther`:**
    - 7 worktree дают 6 сегментов: первые 5 по памяти, затем `MemorySegment(label: "other", bytes: сумма двух, worktree: nil)`;
    - 5 и меньше worktree — без `other`;
    - подпись linked-worktree `PYMEP-3330-overdraft-drawer` — ключ `"PYMEP-3330"` (регулярка `^[A-Z][A-Z0-9]+-\d+`); у остальных — `title`.
  - **`totalsCountEveryProcessOnce`:** `processCount` считает лидеров и участников и не считает дважды pid, который встречается в двух группах; `totalMemory` — сумма `section.memory`.
  - **`aProcessWithoutMemoryOrPorts`:** `footprintBytes == 0` даёт `memory == 0`, `ports == []`.
  - **`queryMatchesWorktreeRepoTitleNamePidAndPort`.** Поиск без учёта регистра. Сначала проверяется совпадение `title` или `repoName` секции: такая секция показывается целиком. Иначе в секции остаются только строки, у которых совпадает `title`, имя любого процесса группы, pid (точное совпадение числа) или порт (`"4200"` или `":4200"`).
  - **`aQueryThatMatchesNothingLeavesNoSection`:** `sections == []`, `bar == []`.
  - **`aGroupThatIsGoneLeavesTheSection`:** после того как из строки пропала последняя группа, секции нет.
  - **`subtitleAndInUse`:**
    - `subtitle == "43 processes in 9 projects · 2.2 GB memory · updated just now"`: «projects» — это число секций; время обновления до 10 с — `just now`, дальше `RelativeDateTimeFormatter` (`.named`, `en_US_POSIX`), например `updated 2 minutes ago`;
    - один процесс и один проект — `"1 process in 1 project · …"`;
    - `inUse(page, of: 15.2 GB) == "2.2 GB of 15.2 GB in use on this Mac"`, при `nil` — `nil`.
- [ ] **Step 2: Run, expect FAIL.** `swift test --package-path Packages/Core --filter ProcessesPageTests`
- [ ] **Step 3: Implement** в `ProcessesPage.swift`. Строки внутри секции идут по убыванию памяти, при равенстве по pid лидера; слитая строка всегда последняя. `SizeFormat.memory` для «GB/MB» не менять.
- [ ] **Step 4: Run, expect PASS.** Затем полный набор.
- [ ] **Step 5: Commit.** `feat(dashboard): model the processes page`

### Task 3: Экран Processes

**Files:**
- Create: `Packages/Core/Sources/AppShell/ProcessesView.swift` (полоса, легенда, таблица)
- Modify: `AppShell/SidebarView.swift` (`SidebarItem.processes`, пункт и бейдж), `AppShell/RootView.swift` (`MainView`: маршрут, заголовок и подзаголовок, поиск, инспектор, `memoryInUse` и `processesSampledAt` из стора), `Tests/AppShellTests/RenderTests.swift`
- Test: рендеры за `AD_RENDER_TESTS=1`, сверка с макетом.

**Interfaces:**
- Consumes:
  - `ProcessesPage`, `ProcessesPresenter` (Task 2);
  - `DashboardStore.memoryInUse`, `processesSampledAt` (Task 1);
  - `RowActions.stop`, `stopping`, `canStop` и `requestStop(_:of:)` из `MainView`;
  - `WorktreeInspector`.
- Produces: `SidebarItem.processes`; `struct ProcessesView: View` с `init(page: ProcessesPage, memoryInUse: () -> UInt64?, selection: Binding<String?>, expanded: Binding<Set<String>>, actions: RowActions)`.

- [ ] **Step 1: Сайдбар.**
  - Пункт `Label("Processes", systemImage: "waveform.path.ecg")` стоит после «Ready to remove».
  - Бейдж — число секций `ProcessesPage(projects:)` без запроса; при 0 бейджа нет.
  - «Caches and Docker» не добавлять, это часть 3.
- [ ] **Step 2: Заголовок.**
  - `navigationTitle("Processes")`.
  - `navigationSubtitle` — `ProcessesPresenter.subtitle` с `updated: processesSampledAt`. Обновляется через `TimelineView(.periodic(from: .now, by: 10))`, чтобы «just now» старел без опроса.
  - Поле поиска общее с Projects, подсказка `Search processes`, пока выбран этот экран.
- [ ] **Step 3: Полоса «Memory by project».**
  - Сверху заголовок `Memory by project` (`.headline`), справа `inUse` (`.callout`, `.secondary`).
  - Ниже горизонтальная полоса высотой 8 pt из сегментов `bar`: ширина пропорциональна `bytes`, между сегментами 2 pt, скругление 3 pt.
  - Цвета по порядку: `.blue, .indigo, .teal, .purple, .pink`; у «other» — `.gray`.
  - Ниже легенда в одну строку: точка цвета, `label`, `SizeFormat.memory(bytes)` (`.secondary`).
  - Клик по сегменту или подписи выделяет секцию этого worktree (`selection`).
- [ ] **Step 4: Таблица** — `Table` с `DisclosureTableRow`, как в `ProjectsTable`.
  - **Колонки:** `Process`, `Kind`, `PID`, `Port`, `Uptime`, `Memory` (по правому краю) и узкая колонка без заголовка для кнопки остановки.
  - **Строка секции:** иконка `folder`, `title` (`.headline`), `subtitle` (`.secondary`), сумма памяти жирным, кнопка остановки всего в worktree (`stop.circle`).
  - **Раскрытие:** по умолчанию раскрыты первые две секции, выбор пользователя запоминается в `expanded` на время работы приложения.
  - **Строка процесса:**
    - иконка `symbol`, у сессии агента оранжевая, у остальных `.secondary`;
    - `title`;
    - `kind`;
    - `pid` моноширинным шрифтом, или `–` у слитой строки;
    - порт: капсула `:4200` (при нескольких портах `:4200 +1`), по клику открывается `http://localhost:4200` через `NSWorkspace`; без портов `—`;
    - `Uptime`: при `isLong` — оранжевая капсула с `timer`, иначе текст; у слитой строки `—`;
    - память;
    - кнопка `stop.circle`, а пока группы строки в `stopping` — спиннер с подписью `Stopping <title>`.
  - **Остановка:** кнопка строки вызывает `requestStop(line.groups, of: section.row)`, кнопка секции — `requestStop(section.row.groups, of: section.row)`. Это тот же диалог и те же правила `canStop`, что в инспекторе.
  - **Выбор:** выбор строки или секции выставляет `selection = section.row.id`, и инспектор показывает `WorktreeInspector` этого worktree.
- [ ] **Step 5: Пустые состояния.**
  - Ничего не запущено: `ContentUnavailableView("Nothing runs in your projects", systemImage: "waveform.path.ecg", description: Text("Processes that run in a project folder, or were started from one, show up here."))`.
  - Поиск ничего не нашёл: `ContentUnavailableView.search(text: query)`.
- [ ] **Step 6: Рендеры.**
  - Добавить в `RenderTests` (только с `AD_RENDER_TESTS=1`) `processesLight` и `processesDark`. Данные — фикстура по макету: dashboard с 5 группами, включая dev server с портом 4200 и сессию 23 ч 56 мин; minuta с сессией 6 д 22 ч, Built here, 3 shells и 2 helpers; три PYMEP-worktree; meetily.
  - Положить PNG в `RENDER_DIR`, сравнить с `docs/superpowers/plans/2026-11-06-processes-mockup.webp` и перечислить в отчёте отличия: отступы, колонки, капсулы, легенду.
- [ ] **Step 7: Run.**
  - Полный `swift test --package-path Packages/Core`, ожидается PASS.
  - Затем `xcodegen generate && xcodebuild -project AgentDashboard.xcodeproj -scheme AgentDashboard -configuration Release -destination 'platform=macOS' -derivedDataPath "$(mktemp -d)" build CODE_SIGN_IDENTITY=-`, ожидается `** BUILD SUCCEEDED **`.
- [ ] **Step 8: Commit.** `feat(appshell): processes page with memory by project and a table of processes`

### Task 4: Проверка на этом маке

- [ ] **Step 1: Сборка.** Контроллер собирает Release в новую папку `/tmp/ad-ddN`, пользователь её запускает.
- [ ] **Step 2: Пользователь проверяет руками.**
  - Сайдбар показывает Processes с бейджем.
  - Цифры памяти близки к Activity Monitor: ±10 % на группу.
  - `inUse` близко к «Memory Used» в Activity Monitor.
  - Сессии Claude старше суток подсвечены.
  - Порт dev-сервера открывает браузер.
  - Остановка `sleep 600`, запущенного в worktree, работает, строка пропадает.
  - Тёмная тема.
- [ ] **Step 3: Нагрузка в простое.** Замерить CPU при открытом экране Processes и окне позади другого приложения. Цель < 1 %, как в части 1.
- [ ] **Step 4: Записать и закоммитить.** Результаты — в раздел «Результат проверки» в конце этого плана, коммит `docs: record verification results for part 2`.

## Результат проверки

Проверено на этом маке 2026-11-09, сборка Release с `a5ae944` (подпись ad-hoc), `/tmp/ad-dd8`.

- Тесты: 750 PASS. Рендеры (`AD_RENDER_TESTS=1`) и Release-сборка проходят.
- Ручная проверка, выполнил пользователь, всё в порядке:
  - пункт Processes с бейджем, «Looking for processes…» до первого опроса;
  - память групп и «in use on this Mac» сходятся с Activity Monitor;
  - подсветка сессий старше суток;
  - порт открывает браузер;
  - остановка `sleep 600`;
  - тёмная тема;
  - ⌘⌫ на этой странице ничего не удаляет.
- Простой после первого скана: 0.94 с CPU за 120 с = 0.8 % (цель < 1 %), память 93 MB (footprint).
- Отличия от макета:
  - у строк-секций нет серой подложки: `Table` не умеет задавать фон одной строке;
  - иконки строк `.secondary`, а не синие.
