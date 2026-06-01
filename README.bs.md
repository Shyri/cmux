<h1 align="center">Chatmux</h1>
<p align="center">Lični fork <a href="https://github.com/manaflow-ai/cmux">cmux</a>-a sa nativnom Claude integracijom, alatima za GitLab radni tok i drugim poboljšanjima kvaliteta života.</p>

<p align="center">
  <a href="#instalacija-iz-izvora">Instalacija iz izvora</a> · <a href="#šta-ovaj-fork-dodaje">Šta ovaj fork dodaje</a> · <a href="#sinhronizacija-sa-upstream">Sinhronizacija sa upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux je izgrađen na vrhu [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — Ghostty-zasnovan macOS terminal sa vertikalnim karticama i obavještenjima za AI kodirajuće agente. Sve što je dokumentovano u [upstream README](https://github.com/manaflow-ai/cmux/blob/main/README.bs.md) i dalje važi: prstenovi obavještenja, in-app pregledač, vertikalne+horizontalne kartice, SSH, Claude Code Teams, vraćanje sesije, cmux CLI/socket API, itd.

Ovaj dokument pokriva samo ono što Chatmux dodaje povrh toga.

## Šta ovaj fork dodaje

### Claude Chat panel

In-app Claude SDK panel koji živi unutar bilo kojeg pane-a — preuzima radni direktorij workspace-a, strimuje odgovore i čuva historiju razgovora po surface-u.

- MCP integracija: ugrađen **MCP Manager** popover za registraciju/upravljanje MCP serverima i health prober koji prikazuje status servera inline
- Slash command registry: definirajte vlastite slash komande po chat-u
- Status line runner: dugotrajni zadaci prikazuju live status liniju u zaglavlju chat-a
- Historija sesija: svaki chat se beleži na disk i može se nastaviti između cmux restartovanja
- Engine pravila dozvola: konfigurirajte koje alate chat može automatski pozvati, a koji zahtijevaju potvrdu

Ugrađena akcija tab bara `cmux.newClaudeChat` otvara novi Claude Chat u fokusiranom pane-u.

### GitLab integracija

Desni sidebar panel u opsegu GitLab projekta workspace-a:

- Lista **Merge Requests** sa filterima po dodijeljenom/autoru i otvaranjem jednim klikom
- Lista **Issues** sa istim sistemom filtera, podržana od `GitLabIssueFiltersStore`
- Lista **Pipelines** sa indikatorima statusa
- Lista **Releases**
- Pregledač **MR Discussions** sa podrškom za three-way diff (`MRDiscussions.swift`)
- Skladišta diff refs i merged-tree tako da pregledač diff-a uvijek zna prave base/target SHA

Koristi vašu lokalnu `glab` / `git` konfiguraciju — nisu potrebni dodatni vjerodajnice.

### Git diff pregledač

Samostalni diff prozor za bilo koji commit, granu ili working tree (`GitDiffWindow.swift`):

- Side-by-side `DiffCodeTextView` i three-way `DiffThreeWayCodeTextView`
- Vlastiti `LCSDiff` engine i `SyntaxHighlighter` za Swift, TypeScript, Markdown, itd.
- Dijeljen sa pregledačem MR diskusija GitLab-a

### Sidebar Workspace Notes

Markdown bilješke po workspace-u koje putuju sa workspace-om:

- Sidebar slot postavljen pored GitLab panela (desni sidebar)
- Auto-arhiviranje kod zatvaranja workspace-a — bilješke se nikad ne gube tiho (vidite sigurnosnu mrežu u `TabManager.closeWorkspace`)
- Samostalan prozor **Notes Manager** (`WorkspaceNotesManagerWindowController`) za pregledanje i vraćanje arhiviranih bilješki kroz sve workspace-ove
- Ugrađena akcija tab bara `cmux.toggleNotes` za prebacivanje sidebar-a sa tastature ili prilagođene komande

### Preseti sesije

Sačuvajte trenutni raspored sesije (panes, surfaces, terminale, URL pregledača, stanje sidebar-a) kao imenovani preset, pa ga kasnije ponovo instancirajte:

- Sačuvaj: `File → Save Session as Preset…` (ili command palette)
- Učitaj: `File → Load Preset → …`
- Ažuriraj: `File → Update Current Preset`
- Skladištenje je u opsegu po bundle-id tako da cmux i Chatmux drže nezavisne kolekcije preseta (`SessionPresetSchema.defaultDirectoryURL`)

### Popoveri MCP Manager + Background Shells

Dva popovera dostupna iz title bara:

- **MCP Manager** — otkrijte, omogućite, onemogućite i provjerite zdravlje MCP servera koje koristi Claude chat
- **Background Shells** — pregledajte odvojene shells pokrenute od chat-a / surface API-ja, pogledajte njihov izlaz i nastavite ih u vidljivom surface-u

### Open in Sourcetree

Nova ugrađena akcija tab bara `cmux.openInSourcetree` pored `openInFinder` i `openInIDE`. Otvara radni direktorij fokusiranog pane-a u [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (ispušta zvuk ako Sourcetree nije instaliran u `/Applications/Sourcetree.app`).

Postavite ga u vlastiti raspored dugmadi u `~/.config/cmux/cmux.json` ili koristite zadani tab bar.

### Skripta za samoinstalaciju

`scripts/install-fork.sh` gradi Release konfiguraciju, ad-hoc potpisuje sa različitim bundle id-om i kopira bundle u `/Applications/Chatmux.app` tako da radi paralelno sa upstream cmux-om:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Zadani identitet:

| Polje | Vrijednost |
|---|---|
| Naziv aplikacije | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Putanja instalacije | `/Applications/Chatmux.app` |

Premostite sa `--name`, `--bundle-id` ili `--dest` ako želite drugačiji identitet (npr. staging build). Fiksiranje bundle id-a kroz `codesign -i <bundle-id>` je kritično za stabilnost macOS TCC dozvola — bez toga, dozvole Documents/App Management se ponovno traže prilikom svakog pokretanja.

Workspace-ovi, snapshoti sesija, preseti, bilješke, MCP konfiguracija i TCC odobrenja su svi indeksirani po `CFBundleIdentifier`, tako da opstaju kroz reinstalacije sve dok držite isti bundle id.

### Slash komanda `/sync-upstream`

Prilagođena Claude Code slash komanda (u `.claude/commands/`) automatizira chatmux ↔ upstream merge ples:

- Fast-forward `main` na `manaflow-ai/cmux:main`
- Zrcali odgovarajući `vendor/bonsplit` submodule pointer na vaš bonsplit fork
- Pravi privremenu granu `chatmux-merge-<timestamp>` i mergea upstream u nju
- Automatski rešava `cmux.xcodeproj/project.pbxproj` konflikte kombinujući obe strane + deduplikujući po ID-u
- Zaustavlja se i prikazuje svaki konflikt u `Sources/`, `Packages/` ili `Resources/` za ljudsko rešavanje
- Pusha privremenu granu i čeka potvrdu build-a prije fast-forward-a `chatmux`-a

Vidite `.claude/commands/sync-upstream.md` za potpuni radni tok i `scripts/sync-upstream-resolve.py` za pbxproj helper.

## Instalacija iz izvora

Chatmux se ne objavljuje kao DMG. Izgradite i instalirajte sa fork skriptom:

```bash
# Klonirajte sa submodulima
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Početno postavljanje (preuzima Ghostty submodul, GhosttyKit, itd.)
./scripts/setup.sh

# Izgradi Release + instaliraj u /Applications/Chatmux.app + pokreni
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Zašto prefiks `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`? Lokalno pokrećemo Zig 0.16, ali Ghostty zahtijeva 0.15.2. Preskakanje zig build-a tjera skriptu da koristi pre-izgrađen GhosttyKit.xcframework iz `manaflow-ai/ghostty` izdanja. Čišćenje `zig-pkg/` drži build key čistim tako da cache hit pre-build-a funkcioniše.

## Sinhronizacija sa upstream

```bash
# Unutar Claude Code sesije u ovom repo:
/sync-upstream
```

Slash komanda obrađuje cijeli merge radni tok uključujući trijažu konflikata. Vidite [Šta ovaj fork dodaje → /sync-upstream](#slash-komanda-sync-upstream).

Za ručne merge-ove, slijedite iste korake u `.claude/commands/sync-upstream.md`.

## Prečice na tastaturi

Sve prečice upstream cmux-a rade nepromijenjene. Vidite [upstream README](https://github.com/manaflow-ai/cmux/blob/main/README.bs.md#keyboard-shortcuts) za kompletnu tabelu. Prečice ekskluzivne za Chatmux su konfigurabilne u Settings → Keyboard Shortcuts i pojavljuju se u `~/.config/cmux/cmux.json` kao i svaka druga cmux prečica.

## Zahvale

Chatmux je fork [cmux](https://github.com/manaflow-ai/cmux)-a od [Manaflow](https://manaflow.com)-a. Sve upstream funkcije i terminal engine su njihove — molim dajte zvjezdicu originalnom projektu i podržite ga.

## Licenca

Ista kao upstream: [GPL-3.0-or-later](LICENSE).
