# Agent Dashboard — план реализации, часть 4: распространение

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Приложение ставится из DMG с GitHub Releases и само обновляется через Sparkle. У него своя иконка. Без Developer ID и нотаризации.

**Architecture:**
- **Версия** живёт в `Config/Version.xcconfig`, как в minuta.
- **Sparkle 2** подключается к таргету приложения через SwiftPM. Апдейтер: `SPUStandardUpdaterController`, пункт меню «Check for Updates…», переключатель в Settings.
- **Фид обновлений** — `appcast.xml`, ассет последнего релиза публичного репозитория `gooonzick/agent-dashboard`.
- **Подпись обновлений** — ключ EdDSA. Приватный ключ лежит только в login keychain.
- **Сборка релиза** — локальный `Scripts/release.sh`: архив, проверка подписи, DMG, appcast.
- **GitHub Actions** — workflow для релиза добавлен, но до появления секретов запускается только вручную.

**Tech Stack:** XcodeGen, xcodebuild, Sparkle 2.10 (SwiftPM + бинарные `generate_keys`/`generate_appcast`), `hdiutil`/`create-dmg`, `gh`.

**Spec:** `docs/superpowers/specs/2026-10-30-agent-dashboard-design.md`, строка 46: «Распространение как у minuta: подпись Developer ID, нотаризация, обновления через Sparkle из GitHub Releases». **Отклонение по решению пользователя (2026-11-17):** Apple Developer аккаунта нет, поэтому подпись ad-hoc, без нотаризации. Всё остальное — как в minuta.

**Образец:** `~/Development/minuta`: `Scripts/release.sh`, `Scripts/ExportOptions.plist`, `.github/workflows/release.yml`, `project.yml` (`SUFeedURL`, `SUPublicEDKey`).

## Global Constraints

- **Подпись ad-hoc.**
  - Hardened Runtime для Release выключен (`ENABLE_HARDENED_RUNTIME: NO`). Нотаризации нет, а с library validation ad-hoc-приложение не загрузит `Sparkle.framework`: документация Sparkle, «Basic Setup».
  - Если позже появится стабильная самоподписанная identity, `release.sh` подписывает ею (переменная `AD_SIGN_IDENTITY`), иначе `-`.
- **`SUFeedURL`:** `https://github.com/gooonzick/agent-dashboard/releases/latest/download/appcast.xml`.
- **Ссылки на скачивание** в appcast: `https://github.com/gooonzick/agent-dashboard/releases/download/v<MARKETING_VERSION>/`.
- **Приватный ключ Sparkle** никогда не попадает в репозиторий, логи и отчёты. В `project.yml` — только `SUPublicEDKey`. Пока ключа нет, стоит заглушка `REPLACE_WITH_PUBLIC_ED_KEY`, и `release.sh` с ней падает, как в minuta.
- **Bundle id** остаётся `dev.gooonzick.AgentDashboard`, иначе пропадут Keychain-токены и настройки.
- **Версии:** первая — `MARKETING_VERSION = 0.1.0`, `CURRENT_PROJECT_VERSION = 1`. Тег — `v<MARKETING_VERSION>`.
- **Действия с внешним миром** выполняются только после явного «да» пользователя в чате:
  - создание репозитория;
  - push;
  - публикация релиза;
  - создание ключа Sparkle;
  - создание identity.
- **Без запросов к пользователю:** тесты не трогают Keychain, сеть и `gh`. Приложение не запускать. Не собирать в `/tmp/ad-dd*`.
- **Коммиты** в формате Conventional Commits. Без push, пока пользователь не скажет.

## Review Focus

1. **Sparkle не загрузился** в ad-hoc сборке (library validation). Проверка: проверка в `release.sh`, что в `codesign -dv` нет `runtime` в `flags=`, и `codesign --verify --deep --strict` в `release.sh`, плюс запуск собранного DMG пользователем в Task 5.
2. **Обновление заменяет приложение, а токены в Keychain остаются.** Bundle id не меняется. Keychain после ad-hoc обновления спросит доступ снова: это известное ограничение, оно записано в README.
3. **Версия в теге не совпадает с `MARKETING_VERSION`,** или `CURRENT_PROJECT_VERSION` не растёт. `release.sh` падает, как в minuta. Тест в Task 1: `bump-version.sh` поднимает build.
4. **Первое открытие скачанного DMG.** Gatekeeper блокирует неподписанное приложение. README говорит, как открыть: System Settings → Privacy & Security → «Open Anyway».
5. **«Check for Updates…» без сети или без релиза.** Sparkle сам показывает ошибку, приложение не падает. Проверяет пользователь в Task 5.

---

### Task 1: Версия и сборка релиза

**Files:**
- Create: `Config/Version.xcconfig`, `Scripts/bump-version.sh`, `Scripts/release.sh`, `README.md` (раздел Release)
- Modify: `project.yml` (`configFiles` с версией, `ENABLE_HARDENED_RUNTIME: NO` для Release, `CODE_SIGN_IDENTITY: "-"` для Release), `.gitignore` (`dist/`)

**Interfaces:**
- Produces:
  - `Scripts/release.sh`: без аргументов; переменные `SPARKLE_BIN`, `SPARKLE_PRIVATE_KEY_FILE` (необязательно, иначе keychain), `AD_SIGN_IDENTITY` (необязательно); результат — `dist/Agent-Dashboard-<ver>.dmg` и `dist/appcast.xml`;
  - `Scripts/bump-version.sh <marketing>`: пишет `MARKETING_VERSION` и увеличивает `CURRENT_PROJECT_VERSION` на 1.

- [ ] **Step 1:** `Config/Version.xcconfig` с `MARKETING_VERSION = 0.1.0` и `CURRENT_PROJECT_VERSION = 1`. Подключить через `configFiles` в `project.yml`. Собранный `Info.plist` должен иметь `CFBundleShortVersionString = 0.1.0` и `CFBundleVersion = 1`; проверить через `plutil -extract` после сборки в `mktemp -d`.
- [ ] **Step 2:** `bump-version.sh` — как в minuta, но короче. Проверка в `mktemp -d` на копии файла: `bump-version.sh 0.2.0` даёт `0.2.0` и build `2`. Неверный аргумент (не `X.Y.Z`) — выход с ошибкой, файл не тронут.
- [ ] **Step 3:** `release.sh` по образцу `~/Development/minuta/Scripts/release.sh`, без нотаризации и экспорта Developer ID.
  - **Сборка:** `xcodegen generate`, затем `xcodebuild archive` (Release, `generic/platform=macOS`). Подпись — `codesign --force --deep --sign "${AD_SIGN_IDENTITY:--}"` на приложении из архива.
  - **Проверки перед упаковкой:**
    - заглушка `REPLACE_WITH_PUBLIC_ED_KEY` в `SUPublicEDKey` — ошибка;
    - тег в `GITHUB_REF_NAME` не равен `v$MARKETING` — ошибка;
    - `codesign --verify --deep --strict`.
  - **DMG:** через `create-dmg`, если он установлен, иначе `hdiutil create -volname "Agent Dashboard" -srcfolder <stage> -format UDZO`. В стейдже приложение и ссылка на `/Applications`.
  - **Appcast:** `generate_appcast` с `--download-url-prefix` из Global Constraints. Ключ берётся из `SPARKLE_PRIVATE_KEY_FILE` или из login keychain.
  - **Где искать `generate_appcast`:** `SPARKLE_BIN` → артефакт SwiftPM `…/artifacts/sparkle/Sparkle/bin` в DerivedData архива → `~/bin/sparkle/bin`.
- [ ] **Step 4:** раздел Release в README:
  - как выпустить релиз: bump, commit, tag, `release.sh`, `gh release create`;
  - как открыть первую установку (Gatekeeper);
  - что Keychain снова спросит доступ после обновления.
- [ ] **Step 5: Проверка.**
  - `bash -n Scripts/*.sh`, `shellcheck`, если установлен.
  - Release-сборка в `mktemp -d` проходит. `release.sh` без ключа Sparkle падает на проверке заглушки с понятным сообщением. До создания ключа это ожидаемо и должно быть указано в отчёте.
  - Полный `swift test --package-path Packages/Core` проходит.
- [ ] **Step 6: Commit.** `build: version file and a local release script`

### Task 2: Sparkle в приложении

**Files:**
- Modify: `project.yml` (пакет `Sparkle` из `https://github.com/sparkle-project/Sparkle`, `from: "2.10.0"`, зависимость таргета `AgentDashboard`; `INFOPLIST_KEY_*` нельзя для кастомных ключей, поэтому `info:` с `properties`: `SUFeedURL`, `SUPublicEDKey: REPLACE_WITH_PUBLIC_ED_KEY`, `SUEnableAutomaticChecks: true`), `App/AgentDashboardApp.swift`
- Create: `App/Updater.swift`
- Modify: `Packages/Core/Sources/AppShell/SettingsView.swift` или новый раздел General (переключатель)

**Interfaces:**
- Produces:
  - `@MainActor final class Updater: ObservableObject`, обёртка над `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`. Публикует `canCheckForUpdates` (KVO `updater.canCheckForUpdates`) и `automaticallyChecksForUpdates` (get/set на `updater`).
  - Пункт меню `Check for Updates…` в группе `CommandGroup(after: .appInfo)`, выключен, пока `!canCheckForUpdates`.
  - Переключатель `Check for updates automatically` в Settings.

  Sparkle живёт только в таргете `App/`. Пакет `Core` о Sparkle не знает. Переключатель попадает в Settings через замыкание или биндинг, который `App` передаёт в `AppShell`, по образцу того, как `RootView` получает стор.

- [ ] **Step 1:** Подключить пакет и ключи `Info.plist`. После `xcodegen generate` и сборки проверить:
  - в собранном `Info.plist` есть `SUFeedURL`, равный значению из Global Constraints;
  - `Sparkle.framework` лежит в `Contents/Frameworks`;
  - `codesign --verify --deep --strict` проходит.
- [ ] **Step 2:** `Updater`, пункт меню, переключатель. Тест в `AppShellTests`, если переключатель живёт в AppShell: он показывает переданное значение и пишет его обратно. Логику самого Sparkle не тестируем.
- [ ] **Step 3:** Release-сборка. Полный набор тестов. Отчёт о размере `Sparkle.framework` и о том, что XPC-сервисы Sparkle не нужны: песочницы нет. Удалять их не обязательно.
- [ ] **Step 4: Commit.** `feat(app): check for updates with Sparkle`

### Task 3: Иконка

**Files:**
- Modify: `agent-dashboard.fig` (новый фрейм «App icon» на странице с макетами)
- Create: `App/Assets.xcassets/AppIcon.appiconset` (16, 32, 128, 256, 512 @1x и @2x + `Contents.json`), `App/Assets.xcassets/Contents.json`
- Modify: `project.yml` (`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`)

- [ ] **Step 1 (контроллер + пользователь).**
  - Контроллер рисует в OpenPencil 3 варианта иконки 1024×1024 в стиле macOS 26: скруглённый квадрат, системная сетка Apple, один ясный символ. Темы на выбор: дерево worktree с метлой, стопка папок со стрелкой вниз, датчик диска с ветками.
  - Экспорт PNG, показать пользователю инлайн, пользователь выбирает.
- [ ] **Step 2:** Нарезать выбранный PNG `sips -z` во все размеры, собрать `AppIcon.appiconset` и подключить. В собранном приложении `Contents/Resources/AppIcon.icns` существует. Рендер Dock-иконки показать пользователю.
- [ ] **Step 3: Commit.** `feat(app): app icon`

### Task 4: Workflow релиза (на будущее)

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1:** По образцу minuta `release.yml`, без шагов Developer ID и нотаризации.
  - **Запуск:** `on: push: tags: ["v*"]` и `workflow_dispatch`.
  - **Шаги:** `brew install xcodegen create-dmg`, скачать Sparkle 2.10.0, записать `secrets.SPARKLE_PRIVATE_KEY` во временный файл, `Scripts/release.sh`, `gh release create` с DMG и appcast.
  - **Первая строка файла** — комментарий: «needs secrets.SPARKLE_PRIVATE_KEY and a runner with Xcode 27; until then releases are built with Scripts/release.sh».
  - **Проверка:** `actionlint`, если установлен; иначе синтаксис YAML через `ruby -ryaml -e`.
- [ ] **Step 2: Commit.** `ci: release workflow for tags`

### Task 5: Первый релиз (контроллер + пользователь, после каждого «да»)

- [ ] **Step 1: Ключ Sparkle.** С разрешения пользователя запустить `generate_keys` из артефакта Sparkle: приватный ключ уходит в login keychain, команда печатает публичный. Вписать публичный в `SUPublicEDKey` в `project.yml`, коммит `build: Sparkle public key`. Приватный ключ не выводить и не копировать.
- [ ] **Step 2: Репозиторий.** С разрешения пользователя: `gh repo create gooonzick/agent-dashboard --public --source . --remote origin`, затем `git push -u origin main`. Перед push проверить, что в истории нет секретов: `git log -p | grep -E "glpat-|ghp_|BEGIN .*PRIVATE"`.
- [ ] **Step 3: Релиз v0.1.0.** Запустить `Scripts/release.sh`. С разрешения пользователя: `git tag v0.1.0 && git push origin v0.1.0`, затем `gh release create v0.1.0 dist/*.dmg dist/appcast.xml --title "Agent Dashboard 0.1.0" --generate-notes`.
- [ ] **Step 4: Пользователь проверяет установку.**
  - Скачать DMG со страницы релиза, перетащить в `/Applications`, открыть через «Open Anyway».
  - Убедиться, что приложение работает.
  - «Check for Updates…» говорит, что версия последняя.
- [ ] **Step 5: Проверка обновления.**
  - `bump-version.sh 0.1.1`, коммит, `release.sh`, тег и релиз v0.1.1 — с разрешения пользователя.
  - В установленной 0.1.0 «Check for Updates…» предлагает 0.1.1, ставит её и перезапускает приложение.
  - About показывает 0.1.1.
- [ ] **Step 6:** Записать результаты в раздел «Результат проверки» этого плана, коммит `docs: record verification results for part 4`.
