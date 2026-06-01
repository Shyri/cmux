<h1 align="center">Chatmux</h1>
<p align="center">Un fork personale di <a href="https://github.com/manaflow-ai/cmux">cmux</a> con integrazione nativa di Claude, strumenti per il flusso di lavoro GitLab e altri miglioramenti di qualità della vita.</p>

<p align="center">
  <a href="#installazione-da-sorgente">Installazione da sorgente</a> · <a href="#cosa-aggiunge-questo-fork">Cosa aggiunge questo fork</a> · <a href="#sincronizzare-con-upstream">Sincronizzare con upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux è costruito su [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), un terminale macOS basato su Ghostty con tab verticali e notifiche per agenti di coding IA. Tutto ciò che è documentato nel [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.it.md) continua a valere: anelli di notifica, browser integrato, tab verticali+orizzontali, SSH, Claude Code Teams, ripristino sessione, CLI/socket API di cmux, ecc.

Questo documento copre solo ciò che Chatmux aggiunge sopra.

## Cosa aggiunge questo fork

### Pannello Claude Chat

Pannello SDK Claude integrato che vive all'interno di qualsiasi pane — prende la directory di lavoro del workspace, fa streaming delle risposte e persiste lo storico della conversazione per superficie.

- Integrazione MCP: popover **MCP Manager** integrato per registrare/gestire server MCP e un health prober che mostra lo stato dei server in linea
- Registro slash command: definisci slash command personalizzati per chat
- Status line runner: le attività di lunga durata renderizzano una status line dal vivo nell'header della chat
- Storico sessioni: ogni chat viene scritta su disco e può essere ripresa attraverso i riavvii di cmux
- Motore di regole di permessi: configura quali tool la chat può invocare automaticamente e quali richiedono conferma

L'azione built-in della tab bar `cmux.newClaudeChat` apre un nuovo Claude Chat nel pane focalizzato.

### Integrazione GitLab

Pannello sidebar destro circoscritto al progetto GitLab del workspace:

- Lista **Merge Requests** con filtri per assegnatario/autore e apertura con un click
- Lista **Issues** con lo stesso sistema di filtri, alimentata da `GitLabIssueFiltersStore`
- Lista **Pipelines** con indicatori di stato
- Lista **Releases**
- Visualizzatore **MR Discussions** con supporto three-way diff (`MRDiscussions.swift`)
- Store di diff refs e merged-tree per far sì che il visualizzatore diff conosca sempre i SHA base/target corretti

Usa la tua configurazione locale `glab` / `git` — nessuna credenziale aggiuntiva necessaria.

### Visualizzatore Git diff

Finestra di diff standalone per qualsiasi commit, branch o working tree (`GitDiffWindow.swift`):

- `DiffCodeTextView` side-by-side e `DiffThreeWayCodeTextView` three-way
- Motore `LCSDiff` personalizzato e `SyntaxHighlighter` per Swift, TypeScript, Markdown, ecc.
- Condiviso con il visualizzatore delle discussioni MR GitLab

### Sidebar Workspace Notes

Note markdown per workspace che viaggiano con il workspace:

- Slot sidebar montato accanto al pannello GitLab (sidebar destra)
- Auto-archiviazione alla chiusura del workspace — le note non vengono mai perse silenziosamente (vedi la rete di sicurezza in `TabManager.closeWorkspace`)
- Finestra standalone **Notes Manager** (`WorkspaceNotesManagerWindowController`) per esplorare e ripristinare le note archiviate di tutti i workspace
- Azione built-in `cmux.toggleNotes` per alternare la sidebar dalla tastiera o da un comando personalizzato

### Preset di sessione

Salva la disposizione corrente della sessione (pane, surface, terminali, URL del browser, stato della sidebar) come preset con nome, e re-istanzialo in seguito:

- Salva: `File → Save Session as Preset…` (o la command palette)
- Carica: `File → Load Preset → …`
- Aggiorna: `File → Update Current Preset`
- L'archiviazione è limitata per bundle-id, così cmux e Chatmux mantengono collezioni di preset indipendenti (`SessionPresetSchema.defaultDirectoryURL`)

### Popover MCP Manager + Background Shells

Due popover raggiungibili dalla barra del titolo:

- **MCP Manager** — scopri, abilita, disabilita ed esegui health-check sui server MCP usati dalla chat Claude
- **Background Shells** — esplora le shell distaccate avviate dalla chat / API surface, sbircia il loro output e riprendile in una surface visibile

### Open in Sourcetree

Nuova azione built-in della tab bar `cmux.openInSourcetree` accanto a `openInFinder` e `openInIDE`. Apre la directory di lavoro del pane focalizzato in [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (emette un beep se Sourcetree non è installato in `/Applications/Sourcetree.app`).

Configuralo nel tuo layout di pulsanti personalizzato in `~/.config/cmux/cmux.json` o affidati alla tab bar di default.

### Script di auto-installazione

`scripts/install-fork.sh` compila la configurazione Release, firma ad-hoc con un bundle id distinto e copia il bundle in `/Applications/Chatmux.app` in modo che funzioni affiancato a cmux upstream:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Identità di default:

| Campo | Valore |
|---|---|
| Nome dell'app | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Percorso di installazione | `/Applications/Chatmux.app` |

Sovrascrivi con `--name`, `--bundle-id` o `--dest` se vuoi un'identità diversa (ad esempio una build di staging). Fissare il bundle id tramite `codesign -i <bundle-id>` è cruciale per la stabilità dei permessi TCC di macOS — senza di esso, i permessi Documents/App Management vengono richiesti nuovamente ad ogni avvio.

Workspace, snapshot di sessione, preset, note, configurazione MCP e autorizzazioni TCC sono tutti indicizzati per `CFBundleIdentifier`, quindi persistono attraverso le re-installazioni finché mantieni lo stesso bundle id.

### Slash command `/sync-upstream`

Uno slash command Claude Code personalizzato (in `.claude/commands/`) automatizza la danza di merge chatmux ↔ upstream:

- Fast-forward di `main` a `manaflow-ai/cmux:main`
- Mirror del puntatore corrispondente del submodulo `vendor/bonsplit` al tuo fork bonsplit
- Crea un branch temporaneo `chatmux-merge-<timestamp>` e merge upstream al suo interno
- Auto-risolve i conflitti di `cmux.xcodeproj/project.pbxproj` combinando entrambi i lati + deduplicando per ID
- Si ferma e mostra qualsiasi conflitto in `Sources/`, `Packages/` o `Resources/` per risoluzione umana
- Pusha il branch temporaneo e attende conferma del build prima di fare fast-forward di `chatmux`

Vedi `.claude/commands/sync-upstream.md` per il workflow completo e `scripts/sync-upstream-resolve.py` per l'helper pbxproj.

## Installazione da sorgente

Chatmux non è pubblicato come DMG. Compila e installa con lo script del fork:

```bash
# Clona con i submoduli
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Setup iniziale (scarica submodulo Ghostty, GhosttyKit, ecc.)
./scripts/setup.sh

# Compila Release + installa in /Applications/Chatmux.app + lancia
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Perché il prefisso `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`? Localmente abbiamo Zig 0.16, ma Ghostty richiede 0.15.2. Saltare il build di Zig forza lo script a usare il GhosttyKit.xcframework precompilato dalle release `manaflow-ai/ghostty`. La pulizia di `zig-pkg/` mantiene la build key pulita così il cache hit del precompilato funziona.

## Sincronizzare con upstream

```bash
# All'interno di una sessione Claude Code in questo repo:
/sync-upstream
```

Lo slash command gestisce l'intero workflow di merge incluso il triage dei conflitti. Vedi [Cosa aggiunge questo fork → /sync-upstream](#slash-command-sync-upstream).

Per merge manuali, segui gli stessi passi in `.claude/commands/sync-upstream.md`.

## Scorciatoie da tastiera

Tutte le scorciatoie cmux upstream funzionano senza modifiche. Vedi il [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.it.md#keyboard-shortcuts) per la tabella completa. Le scorciatoie esclusive di Chatmux sono configurabili in Settings → Keyboard Shortcuts e appaiono in `~/.config/cmux/cmux.json` come qualsiasi altra scorciatoia cmux.

## Crediti

Chatmux è un fork di [cmux](https://github.com/manaflow-ai/cmux) di [Manaflow](https://manaflow.com). Tutte le funzionalità upstream e il motore del terminale sono loro — per favore metti una stella al progetto originale e supportalo.

## Licenza

La stessa di upstream: [GPL-3.0-or-later](LICENSE).
