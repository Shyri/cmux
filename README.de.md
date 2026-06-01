<h1 align="center">Chatmux</h1>
<p align="center">Ein persönlicher Fork von <a href="https://github.com/manaflow-ai/cmux">cmux</a> mit nativer Claude-Integration, GitLab-Workflow-Tools und weiteren Komfortfunktionen.</p>

<p align="center">
  <a href="#installation-aus-dem-quellcode">Installation aus dem Quellcode</a> · <a href="#was-dieser-fork-hinzufügt">Was dieser Fork hinzufügt</a> · <a href="#synchronisation-mit-upstream">Synchronisation mit upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux baut auf [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) auf — einem Ghostty-basierten macOS-Terminal mit vertikalen Tabs und Benachrichtigungen für KI-Coding-Agenten. Alles, was in der [Upstream-README](https://github.com/manaflow-ai/cmux/blob/main/README.de.md) dokumentiert ist, gilt weiterhin: Benachrichtigungsringe, integrierter Browser, vertikale+horizontale Tabs, SSH, Claude Code Teams, Sitzungswiederherstellung, die cmux CLI/Socket-API usw.

Dieses Dokument behandelt nur das, was Chatmux zusätzlich bietet.

## Was dieser Fork hinzufügt

### Claude Chat-Panel

In-App-Claude-SDK-Panel, das in jedem Pane lebt — übernimmt das Arbeitsverzeichnis des Workspaces, streamt Antworten und persistiert den Konversationsverlauf pro Surface.

- MCP-Integration: integriertes **MCP Manager**-Popover zum Registrieren/Verwalten von MCP-Servern und ein Health-Prober, der den Serverstatus inline anzeigt
- Slash-Command-Registry: definiere eigene Slash-Commands pro Chat
- Status-Line-Runner: lang laufende Aufgaben rendern eine Live-Statusleiste im Chat-Header
- Sitzungsverlauf: jeder Chat wird auf die Festplatte journalisiert und kann über cmux-Neustarts hinweg fortgesetzt werden
- Berechtigungsregel-Engine: konfiguriere, welche Tools der Chat automatisch aufrufen darf und welche eine Bestätigung erfordern

Die Tab-Bar-Builtin-Aktion `cmux.newClaudeChat` öffnet einen neuen Claude Chat im fokussierten Pane.

### GitLab-Integration

Rechte-Sidebar-Panel, das auf das GitLab-Projekt des Workspaces beschränkt ist:

- **Merge Requests**-Liste mit Filter nach Assignee/Author und Öffnen per Klick
- **Issues**-Liste mit dem gleichen Filtersystem, gespeist von `GitLabIssueFiltersStore`
- **Pipelines**-Liste mit Statusindikatoren
- **Releases**-Liste
- **MR Discussions**-Viewer mit Three-Way-Diff-Unterstützung (`MRDiscussions.swift`)
- Diff-Refs- und Merged-Tree-Stores, damit der Diff-Viewer immer die richtigen Base/Target-SHAs kennt

Verwendet deine lokale `glab`/`git`-Konfiguration — keine zusätzlichen Zugangsdaten erforderlich.

### Git-Diff-Viewer

Eigenständiges Diff-Fenster für jeden Commit, Branch oder Working Tree (`GitDiffWindow.swift`):

- Side-by-Side `DiffCodeTextView` und Three-Way `DiffThreeWayCodeTextView`
- Eigener `LCSDiff`-Engine und `SyntaxHighlighter` für Swift, TypeScript, Markdown usw.
- Gemeinsam genutzt mit dem GitLab MR Discussions Viewer

### Workspace Notes-Sidebar

Markdown-Notizen pro Workspace, die mit dem Workspace wandern:

- Sidebar-Slot, der neben dem GitLab-Panel (rechte Sidebar) montiert wird
- Auto-Archivierung beim Schließen des Workspaces — Notizen gehen nie still verloren (siehe Sicherheitsnetz in `TabManager.closeWorkspace`)
- Eigenständiges **Notes Manager**-Fenster (`WorkspaceNotesManagerWindowController`) zum Durchsuchen und Wiederherstellen archivierter Notizen aller Workspaces
- Tab-Bar-Builtin-Aktion `cmux.toggleNotes`, um die Sidebar per Tastatur oder benutzerdefinierten Command umzuschalten

### Session-Presets

Speichere das aktuelle Sitzungslayout (Panes, Surfaces, Terminals, Browser-URLs, Sidebar-Status) als benanntes Preset und instanziiere es später neu:

- Speichern: `File → Save Session as Preset…` (oder die Command Palette)
- Laden: `File → Load Preset → …`
- Aktualisieren: `File → Update Current Preset`
- Speicherung ist pro Bundle-ID begrenzt, so dass cmux und Chatmux unabhängige Preset-Sammlungen behalten (`SessionPresetSchema.defaultDirectoryURL`)

### MCP Manager + Background Shells Popovers

Zwei Popovers, die über die Titelleiste erreichbar sind:

- **MCP Manager** — MCP-Server entdecken, aktivieren, deaktivieren und Health-Checks durchführen, die vom Claude Chat verwendet werden
- **Background Shells** — vom Chat / der Surface-API gestartete losgelöste Shells durchsuchen, ihre Ausgabe einsehen und in eine sichtbare Surface zurückholen

### Open in Sourcetree

Neue Tab-Bar-Builtin-Aktion `cmux.openInSourcetree` neben `openInFinder` und `openInIDE`. Öffnet das Arbeitsverzeichnis des fokussierten Panes in [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (Beep, wenn Sourcetree nicht in `/Applications/Sourcetree.app` installiert ist).

Konfiguriere es in deinem eigenen Button-Layout in `~/.config/cmux/cmux.json` oder verlasse dich auf die Standard-Tab-Bar.

### Selbst-Installationsskript

`scripts/install-fork.sh` baut die Release-Konfiguration, signiert ad-hoc mit einer eigenen Bundle-ID und kopiert das Bundle nach `/Applications/Chatmux.app`, damit es parallel zu Upstream-cmux läuft:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Standard-Identität:

| Feld | Wert |
|---|---|
| App-Name | `Chatmux` |
| Bundle-ID | `com.cmuxterm.app.fork` |
| Installationspfad | `/Applications/Chatmux.app` |

Überschreibe mit `--name`, `--bundle-id` oder `--dest`, wenn du eine andere Identität möchtest (z. B. einen Staging-Build). Das Festlegen der Bundle-ID über `codesign -i <bundle-id>` ist entscheidend für stabile macOS-TCC-Berechtigungen — ohne das werden Documents-/App-Management-Berechtigungen bei jedem Start erneut abgefragt.

Workspaces, Sitzungs-Snapshots, Presets, Notizen, MCP-Konfiguration und TCC-Berechtigungen werden alle nach `CFBundleIdentifier` indexiert, sodass sie über Neuinstallationen hinweg erhalten bleiben, solange du die gleiche Bundle-ID behältst.

### `/sync-upstream`-Slash-Command

Ein benutzerdefinierter Claude-Code-Slash-Command (in `.claude/commands/`) automatisiert den chatmux ↔ upstream-Merge-Tanz:

- Fast-Forward von `main` nach `manaflow-ai/cmux:main`
- Spiegelt den passenden `vendor/bonsplit`-Submodule-Pointer zu deinem bonsplit-Fork
- Erstellt einen temporären `chatmux-merge-<timestamp>`-Branch und merged upstream hinein
- Auto-Resolved `cmux.xcodeproj/project.pbxproj`-Konflikte durch Kombination beider Seiten + Deduplizierung nach ID
- Hält an und zeigt jeden Konflikt in `Sources/`, `Packages/` oder `Resources/` für menschliche Auflösung an
- Pusht den temporären Branch und wartet auf Build-Bestätigung, bevor `chatmux` per Fast-Forward aktualisiert wird

Siehe `.claude/commands/sync-upstream.md` für den vollständigen Workflow und `scripts/sync-upstream-resolve.py` für den pbxproj-Helper.

## Installation aus dem Quellcode

Chatmux wird nicht als DMG veröffentlicht. Baue und installiere mit dem Fork-Skript:

```bash
# Mit Submodulen klonen
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Einmalige Einrichtung (lädt Ghostty-Submodule, GhosttyKit usw.)
./scripts/setup.sh

# Release bauen + in /Applications/Chatmux.app installieren + starten
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Warum das Präfix `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`? Lokal läuft Zig 0.16, aber Ghostty benötigt 0.15.2. Das Überspringen des Zig-Builds zwingt das Skript, das vorgebaute GhosttyKit.xcframework aus den `manaflow-ai/ghostty`-Releases zu verwenden. Die `zig-pkg/`-Bereinigung hält den Build-Key sauber, damit der Cache-Hit des Pre-Builds funktioniert.

## Synchronisation mit upstream

```bash
# Innerhalb einer Claude Code-Sitzung in diesem Repo:
/sync-upstream
```

Der Slash-Command übernimmt den vollständigen Merge-Workflow inklusive Konflikt-Triage. Siehe [Was dieser Fork hinzufügt → /sync-upstream](#sync-upstream-slash-command).

Für manuelle Merges folge den gleichen Schritten in `.claude/commands/sync-upstream.md`.

## Tastaturkürzel

Alle Upstream-cmux-Kürzel funktionieren unverändert. Siehe die [Upstream-README](https://github.com/manaflow-ai/cmux/blob/main/README.de.md#keyboard-shortcuts) für die vollständige Tabelle. Chatmux-exklusive Kürzel sind in Settings → Keyboard Shortcuts konfigurierbar und erscheinen in `~/.config/cmux/cmux.json` wie jedes andere cmux-Kürzel.

## Danksagungen

Chatmux ist ein Fork von [cmux](https://github.com/manaflow-ai/cmux) von [Manaflow](https://manaflow.com). Alle Upstream-Funktionen und die Terminal-Engine gehören ihnen — bitte gib dem Original-Projekt einen Stern und unterstütze es.

## Lizenz

Die gleiche wie upstream: [GPL-3.0-or-later](LICENSE).
