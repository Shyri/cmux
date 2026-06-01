<h1 align="center">Chatmux</h1>
<p align="center">네이티브 Claude 통합, GitLab 워크플로 도구, 기타 편의 기능을 추가한 <a href="https://github.com/manaflow-ai/cmux">cmux</a>의 개인 포크입니다.</p>

<p align="center">
  <a href="#소스에서-설치">소스에서 설치</a> · <a href="#이-포크가-추가하는-기능">이 포크가 추가하는 기능</a> · <a href="#upstream과-동기화">upstream과 동기화</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux는 [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 위에 만들어졌습니다 — Ghostty 기반 macOS 터미널로 세로 탭과 AI 코딩 에이전트용 알림을 제공합니다. upstream [README](https://github.com/manaflow-ai/cmux/blob/main/README.ko.md)에 문서화된 모든 기능(알림 링, 인앱 브라우저, 세로+가로 탭, SSH, Claude Code Teams, 세션 복원, cmux CLI/socket API 등)은 그대로 적용됩니다.

이 문서는 Chatmux가 추가로 제공하는 내용만 다룹니다.

## 이 포크가 추가하는 기능

### Claude Chat 패널

모든 페인 내에서 동작하는 인앱 Claude SDK 패널 — 워크스페이스의 작업 디렉터리를 이어받고, 응답을 스트리밍하며, 대화 기록을 surface 단위로 영속화합니다.

- MCP 통합: MCP 서버를 등록/관리하는 빌트인 **MCP Manager** 팝오버와 서버 상태를 인라인으로 표시하는 health prober
- 슬래시 명령 레지스트리: 챗별로 사용자 정의 슬래시 명령을 정의
- Status line runner: 장기 실행 작업이 챗 헤더에 라이브 상태 라인을 렌더링
- 세션 기록: 모든 챗은 디스크에 저널링되어 cmux 재시작에도 이어집니다
- 권한 규칙 엔진: 챗이 자동으로 호출할 수 있는 도구와 확인이 필요한 도구를 설정

탭 바 빌트인 액션 `cmux.newClaudeChat`은 포커스된 페인에 새 Claude Chat을 엽니다.

### GitLab 통합

워크스페이스의 GitLab 프로젝트로 범위가 지정된 오른쪽 사이드바 패널:

- 담당자/작성자 필터와 원클릭 열기 기능이 있는 **Merge Requests** 목록
- `GitLabIssueFiltersStore`가 지원하는 동일한 필터 시스템을 가진 **Issues** 목록
- 상태 표시기가 있는 **Pipelines** 목록
- **Releases** 목록
- three-way diff를 지원하는 **MR Discussions** 뷰어 (`MRDiscussions.swift`)
- diff refs와 merged-tree 저장소로 diff 뷰어가 항상 올바른 base/target SHA를 알 수 있습니다

로컬 `glab` / `git` 설정을 사용 — 추가 자격 증명이 필요 없습니다.

### Git diff 뷰어

모든 커밋, 브랜치 또는 작업 트리를 위한 독립 실행형 diff 창 (`GitDiffWindow.swift`):

- 나란히 보는 `DiffCodeTextView`와 three-way `DiffThreeWayCodeTextView`
- Swift, TypeScript, Markdown 등을 지원하는 사용자 정의 `LCSDiff` 엔진과 `SyntaxHighlighter`
- GitLab MR Discussions 뷰어와 공유

### Workspace Notes 사이드바

워크스페이스와 함께 이동하는 워크스페이스별 markdown 메모:

- GitLab 패널 옆에 마운트된 사이드바 슬롯 (오른쪽 사이드바)
- 워크스페이스 종료 시 자동 아카이브 — 메모는 절대 조용히 사라지지 않습니다 (`TabManager.closeWorkspace`의 안전망 참조)
- 모든 워크스페이스의 아카이브된 메모를 탐색하고 복원하는 독립 **Notes Manager** 창 (`WorkspaceNotesManagerWindowController`)
- 키보드 또는 사용자 정의 명령으로 사이드바를 전환하는 탭 바 빌트인 액션 `cmux.toggleNotes`

### 세션 프리셋

현재 세션 레이아웃(페인, surface, 터미널, 브라우저 URL, 사이드바 상태)을 이름이 있는 프리셋으로 저장하고 나중에 다시 인스턴스화하세요:

- 저장: `File → Save Session as Preset…` (또는 명령 팔레트)
- 로드: `File → Load Preset → …`
- 업데이트: `File → Update Current Preset`
- 저장소는 bundle-id별로 분리되어 cmux와 Chatmux가 독립된 프리셋 컬렉션을 유지합니다 (`SessionPresetSchema.defaultDirectoryURL`)

### MCP Manager + Background Shells 팝오버

타이틀 바에서 접근할 수 있는 두 개의 팝오버:

- **MCP Manager** — Claude 챗이 사용하는 MCP 서버를 검색, 활성화, 비활성화하고 헬스 체크합니다
- **Background Shells** — 챗 / surface API에 의해 시작된 분리된 셸을 탐색하고, 출력을 엿보고, 보이는 surface로 재개합니다

### Open in Sourcetree

`openInFinder`와 `openInIDE` 옆에 있는 새 탭 바 빌트인 액션 `cmux.openInSourcetree`. 포커스된 페인의 작업 디렉터리를 [Atlassian Sourcetree](https://www.sourcetreeapp.com/)에서 엽니다 (`/Applications/Sourcetree.app`에 Sourcetree가 설치되어 있지 않으면 비프음).

`~/.config/cmux/cmux.json`에서 자체 버튼 레이아웃에 연결하거나 기본 탭 바에 맡길 수 있습니다.

### 자체 설치 스크립트

`scripts/install-fork.sh`는 Release 구성을 빌드하고, 별도의 bundle id로 ad-hoc 서명한 후, upstream cmux와 나란히 실행되도록 번들을 `/Applications/Chatmux.app`에 복사합니다:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

기본 ID:

| 필드 | 값 |
|---|---|
| 앱 이름 | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| 설치 경로 | `/Applications/Chatmux.app` |

`--name`, `--bundle-id` 또는 `--dest`로 재정의하여 다른 ID(예: 스테이징 빌드)를 사용할 수 있습니다. `codesign -i <bundle-id>`를 통한 bundle id 고정은 macOS TCC 권한 안정성에 결정적입니다 — 그렇지 않으면 Documents/App Management 권한이 매 실행마다 다시 요청됩니다.

워크스페이스, 세션 스냅샷, 프리셋, 메모, MCP 구성, TCC 권한 부여는 모두 `CFBundleIdentifier`로 인덱싱되므로, 동일한 bundle id를 유지하는 한 재설치 시에도 유지됩니다.

### `/sync-upstream` 슬래시 명령

사용자 정의 Claude Code 슬래시 명령(`.claude/commands/`에 위치)이 chatmux ↔ upstream 병합 절차를 자동화합니다:

- `main`을 `manaflow-ai/cmux:main`으로 fast-forward
- 일치하는 `vendor/bonsplit` 서브모듈 포인터를 bonsplit 포크로 미러링
- 임시 `chatmux-merge-<timestamp>` 브랜치를 생성하고 upstream을 병합
- 양쪽 결합 + ID 기반 중복 제거로 `cmux.xcodeproj/project.pbxproj` 충돌을 자동 해결
- `Sources/`, `Packages/` 또는 `Resources/`의 충돌을 멈추고 사람의 해결을 위해 표시
- 임시 브랜치를 푸시하고 빌드 확인을 기다린 후 `chatmux`를 fast-forward

전체 워크플로는 `.claude/commands/sync-upstream.md`를, pbxproj 헬퍼는 `scripts/sync-upstream-resolve.py`를 참조하세요.

## 소스에서 설치

Chatmux는 DMG로 게시되지 않습니다. 포크 스크립트로 빌드하고 설치하세요:

```bash
# 서브모듈과 함께 클론
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# 일회성 설정 (Ghostty 서브모듈, GhosttyKit 등 가져오기)
./scripts/setup.sh

# Release 빌드 + /Applications/Chatmux.app에 설치 + 실행
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

왜 `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1` 접두사인가요? 로컬에서는 Zig 0.16을 사용하지만 Ghostty는 0.15.2가 필요합니다. Zig 빌드를 건너뛰면 스크립트가 `manaflow-ai/ghostty` 릴리스의 미리 빌드된 GhosttyKit.xcframework를 사용하도록 강제됩니다. `zig-pkg/` 정리는 빌드 키를 깨끗하게 유지하여 미리 빌드된 캐시 히트가 작동하게 합니다.

## upstream과 동기화

```bash
# 이 리포의 Claude Code 세션 내에서:
/sync-upstream
```

이 슬래시 명령은 충돌 분류를 포함한 전체 병합 워크플로를 처리합니다. [이 포크가 추가하는 기능 → /sync-upstream](#sync-upstream-슬래시-명령)을 참조하세요.

수동 병합의 경우 `.claude/commands/sync-upstream.md`의 동일한 단계를 따르세요.

## 키보드 단축키

모든 upstream cmux 단축키는 변경 없이 작동합니다. 전체 표는 [upstream README](https://github.com/manaflow-ai/cmux/blob/main/README.ko.md#keyboard-shortcuts)를 참조하세요. Chatmux 전용 단축키는 Settings → Keyboard Shortcuts에서 설정할 수 있으며 다른 cmux 단축키처럼 `~/.config/cmux/cmux.json`에 표시됩니다.

## 크레딧

Chatmux는 [Manaflow](https://manaflow.com)가 만든 [cmux](https://github.com/manaflow-ai/cmux)의 포크입니다. 모든 upstream 기능과 터미널 엔진은 그들의 것입니다 — 원본 프로젝트에 별을 달고 응원해 주세요.

## 라이선스

upstream과 동일: [GPL-3.0-or-later](LICENSE).
