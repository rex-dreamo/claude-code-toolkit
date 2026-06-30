# Claude Code 설정 툴킷 · Claude Code config toolkit

> 🇰🇷 한국어 먼저 · 🇬🇧 English below ↓

개인 데일리 드라이버 설정에서 추출한, 검증된 **Claude Code 파워유저 패턴** 모음입니다.
팀이 그 메커니즘을 재사용할 수 있도록 공유합니다. 이곳의 모든 파일은 자동화·기계검증
방식의 export로 생성되어 **조직 고유 정보가 구조적으로 제거**되어 있습니다.

## 구성

| 구성요소 | 제공하는 것 |
|---|---|
| **시크릿 가드** (`githooks/`) | 자격증명 형태(AWS/GitHub/AI/Google/Slack 키, 개인키, 하드코딩된 시크릿)와 git-ignore된 `blocklist.local`에 등록한 임의 문자열을 커밋 전에 차단하는 무의존성 `pre-commit` 훅. `core.hooksPath`로 저장소 전체에 설치. |
| **머신 간 메모리 동기화** (`link-claude-memory.sh`, `build-repo-map.sh`, `MEMORY-SYNC.md`) | 두 Mac의 **사용자명이 달라도** iCloud로 Claude의 프로젝트 메모리를 공유하고, git remote 기준으로 키잉하여 repo의 모든 클론을 하나의 버킷으로 수렴. 합집합 전용·비파괴·순환 백업. |
| **리뷰 스킬·커맨드** (`skills/`, `commands/`) | 줌아웃 감사+비전 스킬, 이전 코멘트를 먼저 읽고 dedup하는 PR 리뷰 스킬, dedup 결정 감사 루프, 그리고 의도-정렬 PR 리뷰 커맨드(`pr-intent-review`). |
| **PR 게이트 훅** (`hooks/`) | 모든 리뷰 경로에서 "기존 PR 코멘트 먼저 확인" 강제. |
| **상태줄** (`statusline-command.sh`) | 정보 밀도 높은 Claude Code 상태줄(컨텍스트 바, 모델, PR 배지, 레이트리밋, vim 모드, effort). |
| **agents·commands** | `quick-task`(소작업용 빠른 에이전트), `quick-commit`(스테이징·커밋·푸시 헬퍼). |
| **테스트** (`tests/`) | 모든 스크립트에 대한 격리 테스트. |

## 아키텍처

이 저장소는 **2-레포 모델의 공개 절반**입니다. 평소엔 비공개 `~/.claude` 설정(조직
컨텍스트 전부)에서 작업하고, 큐레이션·기계검증된 부분집합만 이곳으로 export합니다.
**3개 게이트를 통과하기 전엔 아무것도 공개되지 않습니다.**

```
   ▣ 비공개 ~/.claude 설정 (조직 컨텍스트 전부)      ← 항상 여기서 작업
            │  publish.sh
            ▼
   ① 기계 스캔 ── 자격증명 정규식 + git-ignore된 조직 토큰 denylist
            │       (전체 트리 스캔 · 1건이라도 걸리면 차단)
            ▼ 통과
   ② 사람 diff 검수 ── 공개될 정확한 diff를 보여줌
            │       (denylist가 아직 모르는 novel 유출의 마지막 안전망)
            ▼ 승인
   ③ 배포
            │
            ▼
   ▣ 이 공개 레포 (큐레이션된 조직-무관 부분집합)
```

스캔은 **필요조건일 뿐 충분조건이 아닙니다**: denylist는 이미 아는 문자열만 차단하므로,
공개 전에 사람이 diff(게이트 ②)를 한 번 읽습니다.

### 레이아웃

```
.
├── githooks/              # ① 시크릿 가드 + 전체-트리 publish 스캐너
│   ├── pre-commit         #    커밋 시 자격증명/denylist 내용 차단
│   ├── scan-tree.sh       #    publish 게이트로 쓰이는 전체-트리 스캔
│   ├── secret-patterns.sh #    공유 자격증명 정규식 (DRY 출처)
│   └── blocklist.local.example
├── hooks/                 # PR 게이트: 리뷰 전 기존 PR 코멘트 확인
├── skills/                # SKILL.md의 `visibility: public` frontmatter로 옵트인
│   ├── holistic-review/        # 줌아웃 감사 + 창의적 재구성
│   ├── pr-comment-aware-review/ # 새 발견을 기존 PR 코멘트와 dedup
│   ├── review-suppressions/    # dedup 결정 감사
│   └── youtube-download/       # yt-dlp 래퍼
├── agents/                # quick-task — 소규모 독립 작업용 빠른 에이전트
├── commands/              # quick-commit · pr-intent-review (의도-정렬 PR 리뷰)
├── link-claude-memory.sh  # Mac 간 메모리 동기화 엔진 (git remote 기준)
├── build-repo-map.sh      #    repo → 공유 메모리 버킷 매핑
├── MEMORY-SYNC.md         #    메모리 모델 동작 설명
├── statusline-command.sh  # 정보 밀도 높은 상태줄
├── tests/                 # 스크립트별 격리 테스트 (입력을 샌드박싱)
│   ├── githooks/  ├── hooks/  ├── memory-sync/  └── statusline/
├── SECURITY.md            # 4계층 방어 모델 전문
├── README.md  └── LICENSE
```

스킬은 **옵트인**입니다: exporter가 각 스킬의 `SKILL.md` frontmatter에서
`visibility: public` 줄을 읽어 해당 스킬만 포함합니다 — 비공개 스킬은 그 줄을 *안 넣는*
것만으로 비공개로 유지됩니다.

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

## 테스트

```bash
bash tests/githooks/run-all.sh        # 시크릿 가드 + publish 스캐너
bash tests/memory-sync/run-all.sh     # 머신 간 메모리 엔진 (격리)
bash tests/statusline/run-all.sh      # 상태줄 렌더러
bash tests/hooks/run-all.sh           # PR 게이트 훅
```

모든 스위트는 격리되어 있어 입력을 샌드박싱하고 실제 상태를 건드리지 않습니다.

## 빌드 방식

이 저장소는 더 큰 비공개 Claude Code 설정의 **공개 export**입니다. 비공개 저장소에서
`publish.sh`가 조직-무관 파일 allowlist(스킬은 `visibility: public` frontmatter로
옵트인)를 스테이징하고, **전체 트리 스캔에서 시크릿·내부 문자열이 0건일 때만 공개**합니다.
즉, 수동 스크럽이 아니라 구조적으로 깨끗합니다.

## 라이선스

MIT — [`LICENSE`](LICENSE) 참조.

---
---

# Claude Code config toolkit (English)

A small, battle-tested toolkit of **Claude Code power-user patterns**, extracted
from a private daily-driver config and shared so a team can reuse the mechanics.
Every file here is org-free by construction — it is produced by an automated,
machine-verified export (see *How this repo is built*).

## What's inside

| Component | What it gives you |
|---|---|
| **Secret guard** (`githooks/`) | A dependency-free `pre-commit` hook that blocks credential-shaped content (AWS/GitHub/AI/Google/Slack keys, private keys, hardcoded secrets) and any literal you list in a git-ignored `blocklist.local` — so secrets and internal names can't be committed. Installs repo-wide via `core.hooksPath`. |
| **Cross-machine memory sync** (`link-claude-memory.sh`, `build-repo-map.sh`, `MEMORY-SYNC.md`) | Share Claude's per-project memory across multiple Macs through iCloud **even when the machines have different usernames**, and key memory by git remote so every clone of a repo converges to one bucket. Union-only, non-destructive, with rotating backups. |
| **Review skills & commands** (`skills/`, `commands/`) | A zoom-out project-audit-plus-vision skill, a PR review skill that reads prior comments before forming findings (dedup), an audit loop over the dedup decisions, and an intent-alignment PR review command (`pr-intent-review`). |
| **PR-gate hooks** (`hooks/`) | Enforce "consult existing PR comments before reviewing" across every review path. |
| **Statusline** (`statusline-command.sh`) | A compact, information-dense Claude Code status line (context bar, model, PR badge, rate limits, vim mode, effort). |
| **agents & commands** | `quick-task` (fast agent for small jobs), `quick-commit` (stage/commit/push helper). |
| **Tests** (`tests/`) | Hermetic suites for every script — the guard, the memory engine, the statusline. |

## Architecture

This repo is the **public half of a two-repo model**. You keep working in a private
`~/.claude` config (full org context); a curated, machine-verified subset is exported
here. Nothing is published until it clears three gates.

```
   ┌─────────────────────────────┐
   │  private ~/.claude config     │   ← you always edit here
   │  (full org context)           │
   └──────────────┬──────────────┘
                  │  publish.sh
                  ▼
   ① machine scan ───────────────────────────────────────────┐
      credential regex + a git-ignored denylist of org tokens │ fails → blocked
      (whole-tree scan; nothing ships on any hit)             │
                  │ clean                                      │
                  ▼                                            │
   ② human diff   the exact diff that would go public is       │
      review      shown — the last net for a NOVEL leak the    │
                  denylist hasn't learned yet                  │
                  │ approved                                   │
                  ▼                                            │
   ③ deploy ──────────────────────────────────────────────────┘
                  │
                  ▼
   ┌─────────────────────────────┐
   │  this public repo             │   ← curated, org-free subset
   └─────────────────────────────┘
```

The scan is **necessary but not sufficient**: a denylist only blocks strings it
already knows, so a human reads the diff (gate ②) before anything is pushed.

### Layout

```
.
├── githooks/              # ① the secret guard + the whole-tree publish scanner
│   ├── pre-commit         #    blocks credential/denylisted content at commit time
│   ├── scan-tree.sh       #    whole-tree scan used as the publish gate
│   ├── secret-patterns.sh #    shared credential regexes (DRY source)
│   └── blocklist.local.example
├── hooks/                 # PR-gate: consult existing PR comments before reviewing
├── skills/                # opt-in via `visibility: public` frontmatter in SKILL.md
│   ├── holistic-review/        # zoom-out audit + creative reframes
│   ├── pr-comment-aware-review/ # dedup new findings against prior PR comments
│   ├── review-suppressions/    # audit the dedup decisions
│   └── youtube-download/       # yt-dlp wrapper
├── agents/                # quick-task — fast agent for small, isolated tasks
├── commands/              # quick-commit · pr-intent-review (intent-alignment review)
├── link-claude-memory.sh  # cross-Mac memory sync engine (keyed by git remote)
├── build-repo-map.sh      #    repo → shared memory-bucket mapping
├── MEMORY-SYNC.md         #    how the memory model works
├── statusline-command.sh  # compact, information-dense status line
├── tests/                 # hermetic suite per script (sandboxes its own inputs)
│   ├── githooks/  ├── hooks/  ├── memory-sync/  └── statusline/
├── SECURITY.md            # the full four-layer defense model
├── README.md  └── LICENSE
```

Skills are **opt-in**: the exporter reads a `visibility: public` line from each
skill's `SKILL.md` frontmatter and includes only those — so a private skill stays
private just by *not* carrying that line.

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
