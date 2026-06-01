<h1 align="center">Chatmux</h1>
<p align="center">En personlig fork af <a href="https://github.com/manaflow-ai/cmux">cmux</a> med indbygget Claude-integration, GitLab-workflowværktøjer og andre forbedringer.</p>

<p align="center">
  <a href="#installation-fra-kildekode">Installation fra kildekode</a> · <a href="#hvad-denne-fork-tilføjer">Hvad denne fork tilføjer</a> · <a href="#synkronisering-med-upstream">Synkronisering med upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux er bygget oven på [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — en Ghostty-baseret macOS-terminal med lodrette faner og notifikationer for AI-kodningsagenter. Alt dokumenteret i [upstream-README'en](https://github.com/manaflow-ai/cmux/blob/main/README.da.md) gælder stadig: notifikationsringe, indbygget browser, lodrette+vandrette faner, SSH, Claude Code Teams, sessionsgendannelse, cmux CLI/socket-API'en, osv.

Dette dokument dækker kun det, Chatmux tilføjer oveni.

## Hvad denne fork tilføjer

### Claude Chat-panel

Indbygget Claude SDK-panel, der lever inde i enhver rude — henter workspacets arbejdsmappe, streamer svar og bevarer samtalehistorikken pr. surface.

- MCP-integration: indbygget **MCP Manager**-popover til at registrere/administrere MCP-servere og en health prober, der viser serverstatus inline
- Slash-kommando-register: definér dine egne slash-kommandoer pr. chat
- Status line runner: langvarige opgaver gengiver en live statuslinje i chatheaderen
- Sessionshistorik: hver chat journalføres til disk og kan genoptages på tværs af cmux-genstarter
- Tilladelsesregelmotor: konfigurér hvilke værktøjer chatten må kalde automatisk, og hvilke der kræver bekræftelse

Tab bar-indbygget handling `cmux.newClaudeChat` åbner en ny Claude Chat i den fokuserede rude.

### GitLab-integration

Højre sidebar-panel afgrænset til workspacets GitLab-projekt:

- **Merge Requests**-liste med filtre efter tildelt/forfatter og ét-klik-åbning
- **Issues**-liste med samme filtersystem, drevet af `GitLabIssueFiltersStore`
- **Pipelines**-liste med statusindikatorer
- **Releases**-liste
- **MR Discussions**-viewer med three-way diff-understøttelse (`MRDiscussions.swift`)
- Diff refs- og merged-tree-stores så diff-vieweren altid kender de korrekte base/target-SHA'er

Bruger din lokale `glab` / `git`-konfiguration — ingen ekstra legitimation nødvendig.

### Git diff-viewer

Selvstændigt diff-vindue til enhver commit, gren eller working tree (`GitDiffWindow.swift`):

- Side-by-side `DiffCodeTextView` og three-way `DiffThreeWayCodeTextView`
- Brugerdefineret `LCSDiff`-motor og `SyntaxHighlighter` til Swift, TypeScript, Markdown osv.
- Delt med GitLabs MR Discussions-viewer

### Workspace Notes-sidebar

Markdown-noter pr. workspace, der følger med workspace:

- Sidebar-slot monteret ved siden af GitLab-panelet (højre sidebar)
- Auto-arkivering ved lukning af workspace — noter forsvinder aldrig stille (se sikkerhedsnettet i `TabManager.closeWorkspace`)
- Selvstændigt **Notes Manager**-vindue (`WorkspaceNotesManagerWindowController`) til at gennemse og gendanne arkiverede noter på tværs af alle workspaces
- Tab bar-indbygget handling `cmux.toggleNotes` til at skifte sidebar fra tastaturet eller en brugerdefineret kommando

### Sessionspresets

Gem det aktuelle sessionslayout (ruder, surfaces, terminaler, browser-URL'er, sidebar-tilstand) som et navngivet preset, og genskab det senere:

- Gem: `File → Save Session as Preset…` (eller kommandopaletten)
- Indlæs: `File → Load Preset → …`
- Opdatér: `File → Update Current Preset`
- Lagringen er afgrænset pr. bundle-id, så cmux og Chatmux beholder uafhængige presetsamlinger (`SessionPresetSchema.defaultDirectoryURL`)

### MCP Manager + Background Shells-popovers

To popovers tilgængelige fra titellinjen:

- **MCP Manager** — opdage, aktivere, deaktivere og health-checke MCP-servere, som Claude-chatten bruger
- **Background Shells** — gennemse afkoblede shells, der er startet af chatten / surface-API'en, kig i deres output og genoptag dem i en synlig surface

### Open in Sourcetree

Ny tab bar-indbygget handling `cmux.openInSourcetree` ved siden af `openInFinder` og `openInIDE`. Åbner den fokuserede rudes arbejdsmappe i [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (falder tilbage til et bip, hvis Sourcetree ikke er installeret i `/Applications/Sourcetree.app`).

Forbind den i dit eget knaplayout i `~/.config/cmux/cmux.json` eller stol på standard-tab baren.

### Selvinstallationsscript

`scripts/install-fork.sh` bygger Release-konfigurationen, ad-hoc-signerer med et særskilt bundle id og kopierer bundle'et til `/Applications/Chatmux.app`, så det kører side om side med upstream-cmux:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Standardidentitet:

| Felt | Værdi |
|---|---|
| App-navn | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Installationssti | `/Applications/Chatmux.app` |

Tilsidesæt med `--name`, `--bundle-id` eller `--dest`, hvis du vil have en anden identitet (f.eks. et staging-build). At fastgøre bundle id'et via `codesign -i <bundle-id>` er afgørende for stabile macOS TCC-tilladelser — uden det bliver Documents/App Management-tilladelser bedt om igen ved hver opstart.

Workspaces, sessions-snapshots, presets, noter, MCP-konfiguration og TCC-tilladelser er alle indekseret efter `CFBundleIdentifier`, så de overlever geninstallationer, så længe du beholder det samme bundle id.

### `/sync-upstream`-slash-kommando

En brugerdefineret Claude Code slash-kommando (i `.claude/commands/`) automatiserer chatmux ↔ upstream-mergedansen:

- Fast-forwarder `main` til `manaflow-ai/cmux:main`
- Spejler den matchende `vendor/bonsplit`-submodulpointer til din bonsplit-fork
- Opretter en midlertidig `chatmux-merge-<timestamp>`-gren og merger upstream ind i den
- Auto-løser `cmux.xcodeproj/project.pbxproj`-konflikter ved at kombinere begge sider + dedupe efter ID
- Stopper og viser enhver konflikt i `Sources/`, `Packages/` eller `Resources/` til menneskelig løsning
- Pusher den midlertidige gren og venter på build-bekræftelse før fast-forward af `chatmux`

Se `.claude/commands/sync-upstream.md` for det fulde workflow og `scripts/sync-upstream-resolve.py` for pbxproj-hjælperen.

## Installation fra kildekode

Chatmux udgives ikke som DMG. Byg og installér med fork-scriptet:

```bash
# Klon med submoduler
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Engangsopsætning (henter Ghostty-submodul, GhosttyKit osv.)
./scripts/setup.sh

# Byg Release + installer i /Applications/Chatmux.app + start
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Hvorfor præfikset `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`? Lokalt kører vi Zig 0.16, men Ghostty kræver 0.15.2. At springe Zig-build over tvinger scriptet til at bruge den forudbyggede GhosttyKit.xcframework fra `manaflow-ai/ghostty`-releases. Oprydningen af `zig-pkg/` holder build-nøglen ren, så cachehit på pre-build virker.

## Synkronisering med upstream

```bash
# Inde i en Claude Code-session i dette repo:
/sync-upstream
```

Slash-kommandoen håndterer hele merge-workflowet inklusive konflikt-triage. Se [Hvad denne fork tilføjer → /sync-upstream](#sync-upstream-slash-kommando).

For manuelle merges, følg de samme trin i `.claude/commands/sync-upstream.md`.

## Tastaturgenveje

Alle upstream-cmux-genveje virker uændret. Se [upstream-README'en](https://github.com/manaflow-ai/cmux/blob/main/README.da.md#keyboard-shortcuts) for den fulde tabel. Chatmux-eksklusive genveje kan konfigureres via Settings → Keyboard Shortcuts og dukker op i `~/.config/cmux/cmux.json` ligesom enhver anden cmux-genvej.

## Anerkendelser

Chatmux er en fork af [cmux](https://github.com/manaflow-ai/cmux) af [Manaflow](https://manaflow.com). Alle upstream-funktioner og terminal-motoren er deres — vær venlig at give det originale projekt en stjerne og støtte det.

## Licens

Samme som upstream: [GPL-3.0-or-later](LICENSE).
