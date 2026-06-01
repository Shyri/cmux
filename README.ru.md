<h1 align="center">Chatmux</h1>
<p align="center">Личный форк <a href="https://github.com/manaflow-ai/cmux">cmux</a> с нативной интеграцией Claude, инструментами для работы с GitLab и другими улучшениями.</p>

<p align="center">
  <a href="#установка-из-исходного-кода">Установка из исходного кода</a> · <a href="#что-добавляет-этот-форк">Что добавляет этот форк</a> · <a href="#синхронизация-с-upstream">Синхронизация с upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux построен поверх [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — терминала macOS на основе Ghostty с вертикальными вкладками и уведомлениями для ИИ-агентов кодинга. Всё, что описано в [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.ru.md), продолжает работать: кольца уведомлений, встроенный браузер, вертикальные+горизонтальные вкладки, SSH, Claude Code Teams, восстановление сессии, CLI/socket API cmux и т. д.

Этот документ описывает только то, что Chatmux добавляет сверху.

## Что добавляет этот форк

### Панель Claude Chat

Встроенная панель Claude SDK, живущая внутри любой панели — наследует рабочую директорию workspace, стримит ответы и сохраняет историю беседы по surface.

- Интеграция MCP: встроенный поповер **MCP Manager** для регистрации/управления MCP-серверами и health prober, показывающий статус серверов в строке
- Реестр слэш-команд: определяйте собственные слэш-команды для каждого чата
- Status line runner: длительные задачи рендерят живую строку статуса в заголовке чата
- История сессий: каждый чат журналируется на диск и может быть продолжен между перезапусками cmux
- Движок правил разрешений: настройте, какие инструменты чат может вызывать автоматически, а какие требуют подтверждения

Встроенное действие панели вкладок `cmux.newClaudeChat` открывает новый Claude Chat в сфокусированной панели.

### Интеграция GitLab

Панель правой боковой панели, привязанная к GitLab-проекту workspace:

- Список **Merge Requests** с фильтрами по назначенному/автору и открытием в один клик
- Список **Issues** с такой же системой фильтров, на базе `GitLabIssueFiltersStore`
- Список **Pipelines** с индикаторами статуса
- Список **Releases**
- Просмотрщик **MR Discussions** с поддержкой three-way diff (`MRDiscussions.swift`)
- Хранилища diff refs и merged-tree, чтобы просмотрщик diff всегда знал правильные SHA base/target

Использует ваши локальные настройки `glab` / `git` — дополнительные учётные данные не нужны.

### Просмотрщик Git diff

Отдельное окно diff для любого коммита, ветки или рабочего дерева (`GitDiffWindow.swift`):

- Side-by-side `DiffCodeTextView` и three-way `DiffThreeWayCodeTextView`
- Собственный движок `LCSDiff` и `SyntaxHighlighter` для Swift, TypeScript, Markdown и др.
- Используется совместно с просмотрщиком обсуждений MR GitLab

### Боковая панель Workspace Notes

Markdown-заметки на каждый workspace, путешествующие вместе с workspace:

- Слот в боковой панели, монтируемый рядом с панелью GitLab (правая боковая панель)
- Авто-архивация при закрытии workspace — заметки никогда не теряются молча (см. защитную сеть в `TabManager.closeWorkspace`)
- Отдельное окно **Notes Manager** (`WorkspaceNotesManagerWindowController`) для просмотра и восстановления архивированных заметок всех workspace
- Встроенное действие панели вкладок `cmux.toggleNotes` для переключения боковой панели с клавиатуры или пользовательской командой

### Пресеты сессии

Сохраните текущую раскладку сессии (панели, surface, терминалы, URL браузера, состояние боковой панели) как именованный пресет, а затем повторно создайте:

- Сохранить: `File → Save Session as Preset…` (или палитра команд)
- Загрузить: `File → Load Preset → …`
- Обновить: `File → Update Current Preset`
- Хранилище ограничено по bundle-id, так что cmux и Chatmux хранят независимые коллекции пресетов (`SessionPresetSchema.defaultDirectoryURL`)

### Поповеры MCP Manager + Background Shells

Два поповера, доступные из строки заголовка:

- **MCP Manager** — обнаружение, включение, выключение и проверка состояния MCP-серверов, используемых чатом Claude
- **Background Shells** — просмотр отсоединённых shells, запущенных чатом / surface API, подглядывание за их выводом и возобновление в видимом surface

### Open in Sourcetree

Новое встроенное действие панели вкладок `cmux.openInSourcetree` рядом с `openInFinder` и `openInIDE`. Открывает рабочую директорию сфокусированной панели в [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (звуковой сигнал, если Sourcetree не установлен по адресу `/Applications/Sourcetree.app`).

Настройте его в собственной раскладке кнопок в `~/.config/cmux/cmux.json` или используйте панель вкладок по умолчанию.

### Скрипт самоустановки

`scripts/install-fork.sh` собирает конфигурацию Release, подписывает ad-hoc с отдельным bundle id и копирует бандл в `/Applications/Chatmux.app`, чтобы он работал рядом с upstream cmux:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Идентичность по умолчанию:

| Поле | Значение |
|---|---|
| Имя приложения | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Путь установки | `/Applications/Chatmux.app` |

Переопределите с помощью `--name`, `--bundle-id` или `--dest`, если хотите другую идентичность (например, staging-сборку). Закрепление bundle id через `codesign -i <bundle-id>` критично для стабильности разрешений TCC macOS — без этого разрешения Documents/App Management запрашиваются повторно при каждом запуске.

Workspace, снимки сессии, пресеты, заметки, конфигурация MCP и разрешения TCC индексируются по `CFBundleIdentifier`, поэтому они сохраняются между переустановками, пока вы сохраняете одинаковый bundle id.

### Слэш-команда `/sync-upstream`

Пользовательская слэш-команда Claude Code (в `.claude/commands/`) автоматизирует процесс слияния chatmux ↔ upstream:

- Fast-forward `main` к `manaflow-ai/cmux:main`
- Зеркалирует соответствующий указатель подмодуля `vendor/bonsplit` к вашему форку bonsplit
- Создаёт временную ветку `chatmux-merge-<timestamp>` и сливает в неё upstream
- Автоматически разрешает конфликты `cmux.xcodeproj/project.pbxproj` путём объединения обеих сторон + дедупликации по ID
- Останавливается и показывает любой конфликт в `Sources/`, `Packages/` или `Resources/` для разрешения человеком
- Пушит временную ветку и ждёт подтверждения сборки перед fast-forward `chatmux`

См. `.claude/commands/sync-upstream.md` для полного workflow и `scripts/sync-upstream-resolve.py` для помощника pbxproj.

## Установка из исходного кода

Chatmux не публикуется как DMG. Соберите и установите с помощью скрипта форка:

```bash
# Клонировать с подмодулями
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Первоначальная настройка (загружает подмодуль Ghostty, GhosttyKit и т. д.)
./scripts/setup.sh

# Собрать Release + установить в /Applications/Chatmux.app + запустить
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Почему префикс `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`? Локально мы запускаем Zig 0.16, но Ghostty требует 0.15.2. Пропуск сборки Zig заставляет скрипт использовать предсобранный GhosttyKit.xcframework из релизов `manaflow-ai/ghostty`. Очистка `zig-pkg/` поддерживает build key чистым, чтобы попадание в кэш предсборки работало.

## Синхронизация с upstream

```bash
# Внутри сессии Claude Code в этом репозитории:
/sync-upstream
```

Слэш-команда обрабатывает весь рабочий процесс слияния, включая сортировку конфликтов. См. [Что добавляет этот форк → /sync-upstream](#слэш-команда-sync-upstream).

Для ручных слияний следуйте тем же шагам в `.claude/commands/sync-upstream.md`.

## Сочетания клавиш

Все сочетания клавиш upstream cmux работают без изменений. См. [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.ru.md#keyboard-shortcuts) для полной таблицы. Сочетания клавиш только для Chatmux настраиваются в Settings → Keyboard Shortcuts и появляются в `~/.config/cmux/cmux.json`, как и любые другие сочетания клавиш cmux.

## Благодарности

Chatmux — форк [cmux](https://github.com/manaflow-ai/cmux) от [Manaflow](https://manaflow.com). Все функции upstream и движок терминала принадлежат им — пожалуйста, поставьте звезду оригинальному проекту и поддержите его.

## Лицензия

Та же, что и у upstream: [GPL-3.0-or-later](LICENSE).
