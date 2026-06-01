<h1 align="center">Chatmux</h1>
<p align="center">Un fork personnel de <a href="https://github.com/manaflow-ai/cmux">cmux</a> avec une intégration native de Claude, des outils pour le flux de travail GitLab et d'autres améliorations de confort.</p>

<p align="center">
  <a href="#installation-depuis-les-sources">Installation depuis les sources</a> · <a href="#ce-que-ce-fork-ajoute">Ce que ce fork ajoute</a> · <a href="#synchronisation-avec-upstream">Synchronisation avec upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux est construit sur [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), un terminal macOS basé sur Ghostty avec des onglets verticaux et des notifications pour les agents de codage IA. Tout ce qui est documenté dans le [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.fr.md) reste valable : anneaux de notification, navigateur intégré, onglets verticaux+horizontaux, SSH, Claude Code Teams, restauration de session, CLI/socket API de cmux, etc.

Ce document couvre uniquement ce que Chatmux ajoute par-dessus.

## Ce que ce fork ajoute

### Panneau Claude Chat

Panneau SDK Claude intégré qui vit dans n'importe quel volet — il récupère le répertoire de travail de l'espace de travail, diffuse les réponses en streaming et persiste l'historique des conversations par surface.

- Intégration MCP : popover **MCP Manager** intégré pour enregistrer/gérer les serveurs MCP, et un health prober qui affiche l'état des serveurs en ligne
- Registre de slash commands : définissez vos propres slash commands par chat
- Status line runner : les tâches de longue durée affichent une ligne de statut en direct dans l'en-tête du chat
- Historique des sessions : chaque chat est journalisé sur disque et peut être repris entre les redémarrages de cmux
- Moteur de règles de permissions : configurez quels outils le chat peut invoquer automatiquement ou qui nécessitent une confirmation

L'action intégrée de la barre d'onglets `cmux.newClaudeChat` ouvre un nouveau Claude Chat dans le volet focalisé.

### Intégration GitLab

Panneau de la barre latérale droite dédié au projet GitLab de l'espace de travail :

- Liste des **Merge Requests** avec filtres assigné/auteur et ouverture en un clic
- Liste des **Issues** avec le même système de filtres, propulsée par `GitLabIssueFiltersStore`
- Liste des **Pipelines** avec indicateurs d'état
- Liste des **Releases**
- Visualiseur de **MR Discussions** avec support du three-way diff (`MRDiscussions.swift`)
- Stores de diff refs et d'arbre fusionné pour que le visualiseur de diff connaisse toujours les SHA base/cible corrects

Utilise votre configuration locale `glab` / `git` — aucune credential supplémentaire n'est nécessaire.

### Visualiseur de diff Git

Fenêtre de diff autonome pour n'importe quel commit, branche ou working tree (`GitDiffWindow.swift`) :

- `DiffCodeTextView` côte à côte et `DiffThreeWayCodeTextView` à trois voies
- Moteur `LCSDiff` personnalisé et `SyntaxHighlighter` pour Swift, TypeScript, Markdown, etc.
- Partagé avec le visualiseur de discussions de MR GitLab

### Barre latérale Workspace Notes

Notes markdown par espace de travail qui voyagent avec l'espace de travail :

- Emplacement dans la barre latérale monté à côté du panneau GitLab (barre latérale droite)
- Auto-archivage à la fermeture de l'espace de travail — les notes ne sont jamais perdues silencieusement (voir le filet de sécurité dans `TabManager.closeWorkspace`)
- Fenêtre autonome **Notes Manager** (`WorkspaceNotesManagerWindowController`) pour parcourir et restaurer les notes archivées de tous les espaces de travail
- Action intégrée `cmux.toggleNotes` pour basculer la barre latérale depuis le clavier ou une commande personnalisée

### Préréglages de session

Enregistrez la disposition actuelle de la session (volets, surfaces, terminaux, URLs du navigateur, état de la barre latérale) comme préréglage nommé, puis réinstanciez-le plus tard :

- Enregistrer : `File → Save Session as Preset…` (ou la palette de commandes)
- Charger : `File → Load Preset → …`
- Mettre à jour : `File → Update Current Preset`
- Le stockage est limité par bundle-id, ainsi cmux et Chatmux conservent des collections de préréglages indépendantes (`SessionPresetSchema.defaultDirectoryURL`)

### Popovers MCP Manager + Background Shells

Deux popovers accessibles depuis la barre de titre :

- **MCP Manager** — découvrir, activer, désactiver et vérifier l'état des serveurs MCP utilisés par le chat Claude
- **Background Shells** — parcourir les shells détachés lancés par le chat / l'API de surfaces, jeter un œil à leur sortie et les reprendre dans une surface visible

### Open in Sourcetree

Nouvelle action intégrée de la barre d'onglets `cmux.openInSourcetree` à côté de `openInFinder` et `openInIDE`. Ouvre le répertoire de travail du volet focalisé dans [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (émet un bip si Sourcetree n'est pas installé dans `/Applications/Sourcetree.app`).

Configurez-la dans votre propre disposition de boutons dans `~/.config/cmux/cmux.json` ou utilisez la barre d'onglets par défaut.

### Script d'auto-installation

`scripts/install-fork.sh` compile la configuration Release, signe en ad-hoc avec un bundle id distinct et copie le bundle dans `/Applications/Chatmux.app` pour qu'il fonctionne côte à côte avec cmux upstream :

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Identité par défaut :

| Champ | Valeur |
|---|---|
| Nom de l'app | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Chemin d'installation | `/Applications/Chatmux.app` |

Remplacez avec `--name`, `--bundle-id` ou `--dest` si vous voulez une identité différente (par exemple, un build de staging). L'épinglage du bundle id via `codesign -i <bundle-id>` est crucial pour que les permissions TCC de macOS soient stables — sans cela, les permissions Documents/App Management sont redemandées à chaque lancement.

Les espaces de travail, snapshots de session, préréglages, notes, configuration MCP et autorisations TCC sont tous indexés par `CFBundleIdentifier`, ils persistent donc entre les réinstallations tant que vous conservez le même bundle id.

### Slash command `/sync-upstream`

Un slash command Claude Code personnalisé (dans `.claude/commands/`) automatise la danse de merge chatmux ↔ upstream :

- Fast-forward de `main` vers `manaflow-ai/cmux:main`
- Mirroir du pointeur de sous-module `vendor/bonsplit` correspondant vers votre fork bonsplit
- Crée une branche temporaire `chatmux-merge-<timestamp>` et fusionne upstream dedans
- Auto-résout les conflits de `cmux.xcodeproj/project.pbxproj` en combinant les deux côtés + déduplication par ID
- S'arrête et affiche tout conflit dans `Sources/`, `Packages/` ou `Resources/` pour résolution humaine
- Pousse la branche temporaire et attend la confirmation du build avant de fast-forward `chatmux`

Voir `.claude/commands/sync-upstream.md` pour le workflow complet et `scripts/sync-upstream-resolve.py` pour le helper du pbxproj.

## Installation depuis les sources

Chatmux n'est pas publié comme DMG. Compilez et installez avec le script du fork :

```bash
# Cloner avec les sous-modules
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Configuration initiale (récupère le sous-module Ghostty, GhosttyKit, etc.)
./scripts/setup.sh

# Compiler Release + installer dans /Applications/Chatmux.app + lancer
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Pourquoi le préfixe `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1` ? Localement nous utilisons Zig 0.16, mais Ghostty requiert 0.15.2. Sauter le build Zig force le script à utiliser le GhosttyKit.xcframework précompilé depuis les releases `manaflow-ai/ghostty`. Le nettoyage de `zig-pkg/` garde le build key propre pour que le cache hit précompilé fonctionne.

## Synchronisation avec upstream

```bash
# Dans une session Claude Code dans ce dépôt :
/sync-upstream
```

Le slash command gère tout le workflow de merge, y compris le triage des conflits. Voir [Ce que ce fork ajoute → /sync-upstream](#slash-command-sync-upstream).

Pour les merges manuels, suivez les mêmes étapes dans `.claude/commands/sync-upstream.md`.

## Raccourcis clavier

Tous les raccourcis cmux upstream fonctionnent sans changement. Voir le [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.fr.md#keyboard-shortcuts) pour le tableau complet. Les raccourcis exclusifs à Chatmux sont configurables dans Settings → Keyboard Shortcuts et apparaissent dans `~/.config/cmux/cmux.json` comme tout autre raccourci cmux.

## Crédits

Chatmux est un fork de [cmux](https://github.com/manaflow-ai/cmux) par [Manaflow](https://manaflow.com). Toutes les fonctionnalités upstream et le moteur de terminal sont à eux — donnez une étoile au projet original et soutenez-le.

## Licence

La même qu'upstream : [GPL-3.0-or-later](LICENSE).
