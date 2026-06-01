<h1 align="center">Chatmux</h1>
<p align="center">Un fork personal de <a href="https://github.com/manaflow-ai/cmux">cmux</a> con integración nativa de Claude, herramientas para flujo de trabajo con GitLab y otras mejoras de calidad de vida.</p>

<p align="center">
  <a href="#instalación-desde-código-fuente">Instalación desde código fuente</a> · <a href="#qué-añade-este-fork">Qué añade este fork</a> · <a href="#sincronizar-con-upstream">Sincronizar con upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux se construye sobre [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), una terminal para macOS basada en Ghostty con pestañas verticales y notificaciones para agentes de IA. Todo lo documentado en el [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.es.md) sigue siendo válido: anillos de notificación, navegador integrado, pestañas verticales+horizontales, SSH, Claude Code Teams, restauración de sesión, la CLI/socket API de cmux, etc.

Este documento cubre solo lo que Chatmux añade encima.

## Qué añade este fork

### Panel de Claude Chat

Panel del SDK de Claude integrado que vive dentro de cualquier panel — toma el directorio de trabajo del workspace, hace streaming de las respuestas, y persiste el historial de conversación por superficie.

- Integración con MCP: popover **MCP Manager** integrado para registrar/administrar servidores MCP y un health prober que muestra el estado de los servidores en línea
- Registro de slash commands: define tus propios slash commands por chat
- Status line runner: las tareas de larga duración renderizan una línea de estado en vivo en la cabecera del chat
- Historial de sesiones: cada chat se guarda en disco y se puede reanudar entre reinicios de cmux
- Motor de reglas de permisos: configura qué herramientas puede invocar el chat automáticamente y cuáles requieren confirmación

La acción built-in de la barra de pestañas `cmux.newClaudeChat` abre un nuevo Claude Chat en el panel enfocado.

### Integración con GitLab

Panel del sidebar derecho con el proyecto GitLab del workspace:

- Lista de **Merge Requests** con filtros por asignado/autor y apertura con un clic
- Lista de **Issues** con el mismo sistema de filtros, respaldado por `GitLabIssueFiltersStore`
- Lista de **Pipelines** con indicadores de estado
- Lista de **Releases**
- Visor de **Discusiones de MR** con soporte de three-way diff (`MRDiscussions.swift`)
- Stores de diff refs y árbol mergeado para que el visor de diff siempre conozca los SHAs base/target correctos

Usa tu configuración local de `glab` / `git` — no se necesitan credenciales adicionales.

### Visor de diff de Git

Ventana de diff independiente para cualquier commit, rama o working tree (`GitDiffWindow.swift`):

- `DiffCodeTextView` lado a lado y `DiffThreeWayCodeTextView` para tres vías
- Motor propio `LCSDiff` y `SyntaxHighlighter` para Swift, TypeScript, Markdown, etc.
- Compartido con el visor de discusiones de MR de GitLab

### Sidebar de Notas de Workspace

Notas markdown por workspace que viajan con el workspace:

- Slot en el sidebar montado junto al panel de GitLab (sidebar derecho)
- Auto-archivo al cerrar el workspace — las notas nunca se descartan silenciosamente (ver la red de seguridad en `TabManager.closeWorkspace`)
- Ventana independiente **Notes Manager** (`WorkspaceNotesManagerWindowController`) para navegar y restaurar notas archivadas de todos los workspaces
- Acción built-in `cmux.toggleNotes` para alternar el sidebar desde el teclado o desde un comando personalizado

### Presets de sesión

Guarda la disposición actual de la sesión (paneles, superficies, terminales, URLs del navegador, estado del sidebar) como un preset con nombre, y restáuralo después:

- Guardar: `File → Save Session as Preset…` (o el command palette)
- Cargar: `File → Load Preset → …`
- Actualizar: `File → Update Current Preset`
- El almacenamiento es per-bundle-id para que cmux y Chatmux mantengan colecciones de presets independientes (`SessionPresetSchema.defaultDirectoryURL`)

### Popovers de MCP Manager + Background Shells

Dos popovers accesibles desde la barra de título:

- **MCP Manager** — descubre, activa, desactiva y comprueba el estado de los servidores MCP usados por el chat de Claude
- **Background Shells** — navega los shells desacoplados lanzados por el chat o la API de superficies, ojea su salida y reanúdalos en una superficie visible

### Open in Sourcetree

Nueva acción built-in de la barra de pestañas `cmux.openInSourcetree` junto a `openInFinder` y `openInIDE`. Abre el directorio de trabajo del panel enfocado en [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (suena un beep si Sourcetree no está instalado en `/Applications/Sourcetree.app`).

Configúralo en tu propia disposición de botones en `~/.config/cmux/cmux.json` o usa la barra de pestañas por defecto.

### Script de auto-instalación

`scripts/install-fork.sh` compila la configuración Release, firma ad-hoc con un bundle id distinto, y copia el bundle a `/Applications/Chatmux.app` para que funcione junto a cmux upstream:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Identidad por defecto:

| Campo | Valor |
|---|---|
| Nombre de la app | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Ruta de instalación | `/Applications/Chatmux.app` |

Sobrescribe con `--name`, `--bundle-id`, o `--dest` si quieres una identidad distinta (por ejemplo, una build de staging). El fijar el bundle id via `codesign -i <bundle-id>` es crítico para que los permisos de TCC de macOS sean estables — sin esto, los permisos de Documents/App Management se vuelven a solicitar en cada lanzamiento.

Workspaces, snapshots de sesión, presets, notas, configuración MCP y permisos TCC están todos indexados por `CFBundleIdentifier`, así que persisten entre re-instalaciones siempre que mantengas el mismo bundle id.

### Slash command `/sync-upstream`

Un slash command personalizado de Claude Code (en `.claude/commands/`) automatiza la danza de merge chatmux ↔ upstream:

- Hace fast-forward de `main` a `manaflow-ai/cmux:main`
- Espeja el puntero correspondiente del submódulo `vendor/bonsplit` a tu fork de bonsplit
- Crea una rama temporal `chatmux-merge-<timestamp>` y mergea upstream en ella
- Auto-resuelve los conflictos de `cmux.xcodeproj/project.pbxproj` combinando ambos lados + deduplicando por ID
- Se detiene y muestra cualquier conflicto en `Sources/`, `Packages/`, o `Resources/` para resolución humana
- Pushea la rama temporal y espera confirmación del build antes de hacer fast-forward de `chatmux`

Ver `.claude/commands/sync-upstream.md` para el flujo completo y `scripts/sync-upstream-resolve.py` para el helper del pbxproj.

## Instalación desde código fuente

Chatmux no se publica como DMG. Compila e instala con el script del fork:

```bash
# Clonar con submódulos
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# Configuración inicial (descarga submódulo Ghostty, GhosttyKit, etc.)
./scripts/setup.sh

# Compilar Release + instalar en /Applications/Chatmux.app + lanzar
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

¿Por qué el prefijo `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`? Localmente corremos Zig 0.16, pero Ghostty requiere 0.15.2. Saltar el zig build fuerza al script a usar el GhosttyKit.xcframework precompilado desde los releases de `manaflow-ai/ghostty`. La limpieza de `zig-pkg/` mantiene el build key limpio para que el cache hit del precompilado funcione.

## Sincronizar con upstream

```bash
# Dentro de una sesión de Claude Code en este repo:
/sync-upstream
```

El slash command maneja todo el flujo de merge incluyendo el triage de conflictos. Ver [Qué añade este fork → /sync-upstream](#slash-command-sync-upstream).

Para merges manuales, sigue los mismos pasos en `.claude/commands/sync-upstream.md`.

## Atajos de teclado

Todos los atajos de cmux upstream funcionan sin cambios. Ver el [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.es.md#keyboard-shortcuts) para la tabla completa. Los atajos exclusivos de Chatmux son configurables en Settings → Keyboard Shortcuts y aparecen en `~/.config/cmux/cmux.json` como cualquier otro atajo de cmux.

## Créditos

Chatmux es un fork de [cmux](https://github.com/manaflow-ai/cmux) por [Manaflow](https://manaflow.com). Todas las funcionalidades de upstream y el motor de terminal son suyos — por favor dale star al proyecto original y apóyalo.

## Licencia

La misma que upstream: [GPL-3.0-or-later](LICENSE).
