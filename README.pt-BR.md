<h1 align="center">Chatmux</h1>
<p align="center">Um fork pessoal do <a href="https://github.com/manaflow-ai/cmux">cmux</a> com integração nativa do Claude, ferramentas para fluxo de trabalho com GitLab e outras melhorias de qualidade de vida.</p>

<p align="center">
  <a href="#instalação-a-partir-do-código-fonte">Instalação a partir do código-fonte</a> · <a href="#o-que-este-fork-adiciona">O que este fork adiciona</a> · <a href="#sincronizar-com-upstream">Sincronizar com upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

O Chatmux é construído sobre o [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — um terminal macOS baseado em Ghostty com abas verticais e notificações para agentes de codificação de IA. Tudo o que está documentado no [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.pt-BR.md) continua valendo: anéis de notificação, navegador integrado, abas verticais+horizontais, SSH, Claude Code Teams, restauração de sessão, CLI/socket API do cmux, etc.

Este documento cobre apenas o que o Chatmux adiciona por cima.

## O que este fork adiciona

### Painel Claude Chat

Painel SDK Claude integrado que vive dentro de qualquer painel — pega o diretório de trabalho do workspace, faz streaming das respostas e persiste o histórico de conversa por surface.

- Integração MCP: popover **MCP Manager** integrado para registrar/gerenciar servidores MCP e um health prober que mostra o status dos servidores inline
- Registro de slash commands: defina seus próprios slash commands por chat
- Status line runner: tarefas de longa duração renderizam uma linha de status ao vivo no cabeçalho do chat
- Histórico de sessões: cada chat é gravado em disco e pode ser retomado entre reinicializações do cmux
- Motor de regras de permissão: configure quais ferramentas o chat pode invocar automaticamente e quais exigem confirmação

A ação built-in da tab bar `cmux.newClaudeChat` abre um novo Claude Chat no painel focado.

### Integração com GitLab

Painel da barra lateral direita com escopo no projeto GitLab do workspace:

- Lista de **Merge Requests** com filtros por designado/autor e abertura em um clique
- Lista de **Issues** com o mesmo sistema de filtros, alimentada por `GitLabIssueFiltersStore`
- Lista de **Pipelines** com indicadores de status
- Lista de **Releases**
- Visualizador de **MR Discussions** com suporte a three-way diff (`MRDiscussions.swift`)
- Stores de diff refs e merged-tree para que o visualizador de diff sempre conheça os SHAs base/target corretos

Usa sua configuração local `glab` / `git` — nenhuma credencial extra necessária.

### Visualizador de Git diff

Janela de diff independente para qualquer commit, branch ou working tree (`GitDiffWindow.swift`):

- `DiffCodeTextView` lado a lado e `DiffThreeWayCodeTextView` de três vias
- Motor `LCSDiff` próprio e `SyntaxHighlighter` para Swift, TypeScript, Markdown, etc.
- Compartilhado com o visualizador de discussões de MR do GitLab

### Barra lateral Workspace Notes

Notas markdown por workspace que viajam com o workspace:

- Slot na barra lateral montado ao lado do painel do GitLab (barra lateral direita)
- Auto-arquivamento ao fechar o workspace — as notas nunca são silenciosamente perdidas (veja a rede de segurança em `TabManager.closeWorkspace`)
- Janela independente **Notes Manager** (`WorkspaceNotesManagerWindowController`) para navegar e restaurar notas arquivadas de todos os workspaces
- Ação built-in `cmux.toggleNotes` para alternar a barra lateral via teclado ou comando personalizado

### Presets de sessão

Salve o layout atual da sessão (painéis, surfaces, terminais, URLs do navegador, estado da barra lateral) como um preset nomeado e reinstancie-o depois:

- Salvar: `File → Save Session as Preset…` (ou a paleta de comandos)
- Carregar: `File → Load Preset → …`
- Atualizar: `File → Update Current Preset`
- O armazenamento tem escopo por bundle-id, então cmux e Chatmux mantêm coleções de presets independentes (`SessionPresetSchema.defaultDirectoryURL`)

### Popovers MCP Manager + Background Shells

Dois popovers acessíveis pela barra de título:

- **MCP Manager** — descubra, ative, desative e verifique o status dos servidores MCP usados pelo chat Claude
- **Background Shells** — navegue pelos shells desacoplados iniciados pelo chat / API de surfaces, espie a saída e retome-os em uma surface visível

### Open in Sourcetree

Nova ação built-in da tab bar `cmux.openInSourcetree` ao lado de `openInFinder` e `openInIDE`. Abre o diretório de trabalho do painel focado no [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (emite um beep se o Sourcetree não estiver instalado em `/Applications/Sourcetree.app`).

Configure-o em seu próprio layout de botões em `~/.config/cmux/cmux.json` ou confie na tab bar padrão.

### Script de auto-instalação

`scripts/install-fork.sh` compila a configuração Release, assina ad-hoc com um bundle id distinto e copia o bundle para `/Applications/Chatmux.app` para que funcione lado a lado com o cmux upstream:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Identidade padrão:

| Campo | Valor |
|---|---|
| Nome do app | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Caminho de instalação | `/Applications/Chatmux.app` |

Substitua com `--name`, `--bundle-id` ou `--dest` se quiser uma identidade diferente (por exemplo, um build de staging). Fixar o bundle id via `codesign -i <bundle-id>` é crucial para estabilidade dos permissionamentos TCC do macOS — sem isso, permissões de Documents/App Management são solicitadas novamente a cada inicialização.

Workspaces, snapshots de sessão, presets, notas, configuração MCP e autorizações TCC são todos indexados por `CFBundleIdentifier`, então persistem entre re-instalações enquanto você mantiver o mesmo bundle id.

### Slash command `/sync-upstream`

Um slash command Claude Code personalizado (em `.claude/commands/`) automatiza a dança de merge chatmux ↔ upstream:

- Fast-forward de `main` para `manaflow-ai/cmux:main`
- Espelha o ponteiro correspondente do submódulo `vendor/bonsplit` para seu fork bonsplit
- Cria um branch temporário `chatmux-merge-<timestamp>` e faz merge do upstream nele
- Auto-resolve conflitos em `cmux.xcodeproj/project.pbxproj` combinando ambos os lados + deduplicando por ID
- Para e exibe qualquer conflito em `Sources/`, `Packages/` ou `Resources/` para resolução humana
- Pusha o branch temporário e aguarda confirmação do build antes de fazer fast-forward do `chatmux`

Veja `.claude/commands/sync-upstream.md` para o workflow completo e `scripts/sync-upstream-resolve.py` para o helper do pbxproj.

## Instalação a partir do código-fonte

O Chatmux não é publicado como DMG. Compile e instale com o script do fork:

```bash
# Clonar com submódulos
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Setup inicial (busca submódulo Ghostty, GhosttyKit, etc.)
./scripts/setup.sh

# Compilar Release + instalar em /Applications/Chatmux.app + lançar
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Por que o prefixo `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`? Localmente rodamos Zig 0.16, mas o Ghostty requer 0.15.2. Pular o build do Zig força o script a usar o GhosttyKit.xcframework pré-compilado dos releases `manaflow-ai/ghostty`. A limpeza do `zig-pkg/` mantém a build key limpa para que o cache hit do pré-compilado funcione.

## Sincronizar com upstream

```bash
# Dentro de uma sessão Claude Code neste repo:
/sync-upstream
```

O slash command lida com todo o workflow de merge incluindo a triagem de conflitos. Veja [O que este fork adiciona → /sync-upstream](#slash-command-sync-upstream).

Para merges manuais, siga os mesmos passos em `.claude/commands/sync-upstream.md`.

## Atalhos de teclado

Todos os atalhos do cmux upstream funcionam sem alterações. Veja o [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.pt-BR.md#keyboard-shortcuts) para a tabela completa. Os atalhos exclusivos do Chatmux são configuráveis em Settings → Keyboard Shortcuts e aparecem em `~/.config/cmux/cmux.json` como qualquer outro atalho do cmux.

## Créditos

O Chatmux é um fork do [cmux](https://github.com/manaflow-ai/cmux) por [Manaflow](https://manaflow.com). Todas as funcionalidades upstream e o motor do terminal são deles — por favor, dê uma estrela ao projeto original e apoie-o.

## Licença

A mesma do upstream: [GPL-3.0-or-later](LICENSE).
