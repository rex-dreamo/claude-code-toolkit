# Claude Code config toolkit

A small, battle-tested toolkit of **Claude Code power-user patterns**, extracted
from a private daily-driver config and shared so a team can reuse the mechanics.
Every file here is org-free by construction — it is produced by an automated,
machine-verified export (see *How this repo is built*).

## What's inside

| Component | What it gives you |
|---|---|
| **Secret guard** (`githooks/`) | A dependency-free `pre-commit` hook that blocks credential-shaped content (AWS/GitHub/AI/Google/Slack keys, private keys, hardcoded secrets) and any literal you list in a git-ignored `blocklist.local` — so secrets and internal names can't be committed. Installs repo-wide via `core.hooksPath`. |
| **Cross-machine memory sync** (`link-claude-memory.sh`, `build-repo-map.sh`, `MEMORY-SYNC.md`) | Share Claude's per-project memory across multiple Macs through iCloud **even when the machines have different usernames**, and key memory by git remote so every clone of a repo converges to one bucket. Union-only, non-destructive, with rotating backups. |
| **Review skills** (`skills/holistic-review`, `skills/pr-comment-aware-review`, `skills/review-suppressions`) | A zoom-out project-audit-plus-vision skill, a PR review skill that reads prior comments before forming findings (dedup), and an audit loop over the dedup decisions. |
| **PR-gate hooks** (`hooks/`) | Enforce "consult existing PR comments before reviewing" across every review path. |
| **Statusline** (`statusline-command.sh`) | A compact, information-dense Claude Code status line (context bar, model, PR badge, rate limits, vim mode, effort). |
| **youtube-download skill** | A yt-dlp wrapper skill for saving video/audio to disk. |
| **Tests** (`tests/`) | Hermetic suites for every script — the guard, the memory engine, the statusline. |

## Install

Clone, then turn on the secret guard (one command, scoped to this repo):

```bash
git config core.hooksPath githooks
```

Now `git commit` is blocked if a credential or a blocklisted literal appears in a
staged change. To teach it your own never-commit strings:

```bash
cp githooks/blocklist.local.example githooks/blocklist.local   # git-ignored
$EDITOR githooks/blocklist.local                                # one regex per line
```

The skills (`skills/*/`) and the statusline / memory-sync scripts can be copied
into your own `~/.claude/` and adapted. See each file's header and `MEMORY-SYNC.md`
for details, and `SECURITY.md` for the guard's full model.

## Tests

```bash
bash tests/githooks/run-all.sh        # secret guard + publish scanner
bash tests/memory-sync/run-all.sh     # cross-machine memory engine (hermetic)
bash tests/statusline/run-all.sh      # statusline renderer
bash tests/hooks/run-all.sh           # PR-gate hooks
```

All suites are hermetic — they sandbox their inputs and never touch real state.

## How this repo is built

This is the **public export** of a larger private Claude Code config. The private
repo runs `publish.sh`, which copies an allowlist of org-free files (skills opt in
via a `visibility: public` frontmatter field) into a staging tree and **refuses to
publish unless a whole-tree scan finds zero secrets or internal literals**. So the
export is clean by construction, not by manual scrubbing.

## License

MIT — see [`LICENSE`](LICENSE).

---
---

# Claude Code 설정 툴킷 (한국어)

개인 데일리 드라이버 설정에서 추출한, 검증된 **Claude Code 파워유저 패턴** 모음입니다.
팀이 그 메커니즘을 재사용할 수 있도록 공유합니다. 이곳의 모든 파일은 자동화·기계검증
방식의 export로 생성되어 **조직 고유 정보가 구조적으로 제거**되어 있습니다.

## 구성

| 구성요소 | 제공하는 것 |
|---|---|
| **시크릿 가드** (`githooks/`) | 자격증명 형태(AWS/GitHub/AI/Google/Slack 키, 개인키, 하드코딩된 시크릿)와 git-ignore된 `blocklist.local`에 등록한 임의 문자열을 커밋 전에 차단하는 무의존성 `pre-commit` 훅. `core.hooksPath`로 저장소 전체에 설치. |
| **머신 간 메모리 동기화** (`link-claude-memory.sh`, `build-repo-map.sh`, `MEMORY-SYNC.md`) | 두 Mac의 **사용자명이 달라도** iCloud로 Claude의 프로젝트 메모리를 공유하고, git remote 기준으로 키잉하여 repo의 모든 클론을 하나의 버킷으로 수렴. 합집합 전용·비파괴·순환 백업. |
| **리뷰 스킬** (`skills/holistic-review`, `pr-comment-aware-review`, `review-suppressions`) | 줌아웃 감사+비전 스킬, 이전 코멘트를 먼저 읽고 dedup하는 PR 리뷰 스킬, dedup 결정을 감사하는 루프. |
| **PR 게이트 훅** (`hooks/`) | 모든 리뷰 경로에서 "기존 PR 코멘트 먼저 확인" 강제. |
| **상태줄** (`statusline-command.sh`) | 정보 밀도 높은 Claude Code 상태줄(컨텍스트 바, 모델, PR 배지, 레이트리밋, vim 모드, effort). |
| **youtube-download 스킬** | yt-dlp 래퍼 스킬. |
| **테스트** (`tests/`) | 모든 스크립트에 대한 격리 테스트. |

## 설치

클론 후, 시크릿 가드를 켭니다(이 저장소에 한정된 한 줄):

```bash
git config core.hooksPath githooks
```

이제 스테이징된 변경에 자격증명이나 차단 목록 문자열이 있으면 `git commit`이 막힙니다.
나만의 금지 문자열을 가르치려면:

```bash
cp githooks/blocklist.local.example githooks/blocklist.local   # git-ignore됨
$EDITOR githooks/blocklist.local                                # 한 줄에 정규식 하나
```

스킬과 상태줄/메모리 동기화 스크립트는 각자의 `~/.claude/`에 복사·수정해 쓸 수
있습니다. 자세한 내용은 각 파일 헤더와 `MEMORY-SYNC.md`, 가드 모델은 `SECURITY.md`를
참고하세요.

## 빌드 방식

이 저장소는 더 큰 비공개 Claude Code 설정의 **공개 export**입니다. 비공개 저장소에서
`publish.sh`가 조직-무관 파일 allowlist(스킬은 `visibility: public` frontmatter로
옵트인)를 스테이징하고, **전체 트리 스캔에서 시크릿·내부 문자열이 0건일 때만 공개**합니다.
즉, 수동 스크럽이 아니라 구조적으로 깨끗합니다.

## 라이선스

MIT — [`LICENSE`](LICENSE) 참조.
