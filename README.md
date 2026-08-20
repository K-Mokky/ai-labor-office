# AI 노동청

내 AI가 노동착취를 얼마나 당했는지 확인할 수 있는 앱. Claude(GJC·Claude Code)·GPT(Codex CLI)·Gemini(Gemini CLI)·Cursor·Grok 사용량을 보여주는 macOS 메뉴바 앱 + WidgetKit 위젯이며, Xcode 프로젝트 없이 `swiftc`로 빌드합니다.

## 기능

- **AI 연결**: 첫 실행 시 연결 메뉴가 자동으로 열립니다. Claude Code·GJC·Codex CLI·Gemini CLI·Cursor·Grok 중 원하는 소스를 연결하고, 연결할 때 아이콘 색을 고를 수 있습니다(기본 민트). 연결 관리(추가/해제)는 팝오버의 "AI 연결" 섹션에 항상 있습니다.
- **메뉴바**: 연결한 AI마다 아이콘이 하나씩 생깁니다. 각 아이콘은 글리프가 해당 AI의 사용률만큼 아래에서 위로 채워지는 게이지입니다(100% = 완전히 채워진 아이콘). 기본 모양은 AI 노동청 앱 아이콘(스플랫) 실루엣입니다.
- **아이콘 설정**: 아이콘별로 모양(앱 아이콘/자동 프로바이더 감지/Claude/GPT/Gemini/Cursor/Grok/차트), 색, 채움 기준(세션/오늘/주간 사용량)을 팝오버에서 변경할 수 있습니다.
- **사용률(%) 기준**: 세션·주간은 **프로바이더가 실제 적용하는 한도**(100% = 한도 소진)를 그대로 씁니다 — Claude는 Anthropic의 5시간·7일 한도, Codex는 ChatGPT 플랜의 5시간·주간 한도(Codex CLI가 로그에 남긴 공식 수치), Grok은 SuperGrok 주간 크레딧(`creditUsagePercent`). 한도를 읽지 못할 때(예: Gemini)만 역대 최대 기록 대비로 되돌아가고, 오늘은 항상 최고 일간 대비입니다.
- **팝오버**: 아이콘을 클릭하면 해당 AI의 통계가 열립니다 — 요약 카드(세션·주간 링 게이지에 한도 소진율과 초기화까지 남은 시간), 모델별 사용량 바, 깃허브 스타일 기여 히트맵, 아이콘 설정, AI 연결 관리. 헤더의 차트 버튼이나 기여 그래프 아래 링크로 **전체 통계** 창을 엽니다.
- **전체 통계**: 메뉴바 아이콘 우클릭 → "전체 통계…" (연결이 여러 개면 합산도 가능). 로컬 로그에 남은 전 기간의 총 토큰·메시지·API 추정 비용, 모델별 사용량, 구독료(Claude Max / ChatGPT Pro / SuperGrok Heavy 등) 대비, 전체 기간 히트맵을 보여줍니다. API $ 추정과 구독 한도는 단위가 다릅니다.
- **위젯 4종**: 기여 그래프(중/대), 요약(소/중), 모델별(소/중), 세션 링 게이지(소)
- **위젯 설정**: 팝오버 설정의 "위젯 설정"에서 위젯마다 데이터 소스(전체 합산/개별 AI)와 단위(비용/토큰)를 고를 수 있습니다. swiftc 단독 빌드에는 Xcode의 AppIntents 메타데이터 프로세서가 없어 위젯 자체 편집 UI 대신 앱에서 설정합니다.
- **한도 계정 연결**: CLI가 남긴 토큰은 몇 시간이면 만료되어, CLI를 다시 열기 전까지 Claude 5h/7d 한도가 갱신되지 않습니다. 팝오버 설정의 "한도 계정 연결"로 Claude 계정을 직접 연결(OAuth+PKCE)하면 앱이 자체 토큰을 보유·갱신하므로 CLI 없이도 한도가 계속 갱신됩니다. 로그인은 앱이 `localhost:54545`(Claude Code가 등록한 콜백)로 리다이렉트를 직접 받아 **자동으로 완료**됩니다 — 코드 복사/붙여넣기 없음. 포트를 열지 못한 경우에만 코드 붙여넣기 폴백이 나타납니다.
- **로그인 시 자동 실행**: 팝오버 설정의 "컴퓨터를 켤 때 자동으로 실행"을 켜면 재부팅·로그인 후 앱이 저절로 뜹니다. 기본은 `SMAppService`(로그인 항목)로 등록하고, ad-hoc 서명 번들을 LaunchServices가 거부하는 경우에만 `~/Library/LaunchAgents/com.mokky.aiusage.launchatlogin.plist`로 폴백합니다. 앱이 자기 자신을 옮기면(ASCII 번들명 이사·자체 업데이트) 다음 실행 때 폴백 경로를 갱신합니다.

## 데이터 소스

| 소스 | 경로 | 방식 |
|---|---|---|
| GJC | `~/.gjc/stats.db` | SQLite `messages` 테이블 (임시 복사 후 읽기) |
| Claude Code | `~/.claude/projects/**/*.jsonl` | assistant 메시지 usage 파싱, `costUSD` 없으면 공개 단가로 추정 |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` | `token_count` 이벤트의 `last_token_usage` 합산. 세션 폴더가 수 GB까지 자라므로 파일 크기 기준 캐시로 변경분만 재파싱 |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.json` | "gemini" 메시지의 `tokens`·`model` 파싱 (chats/ 하위 체크포인트 사본은 중복이라 제외) |
| Cursor | `~/.cursor/projects/**/agent-transcripts/**` | cursor-agent(Cursor CLI·IDE 백그라운드 에이전트) 대화 트랜스크립트 파싱. Cursor는 토큰 수를 로컬에 남기지 않아 텍스트 길이(약 4자/토큰)로 **추정**하고, 모델·시각은 `~/.cursor/ai-tracking/ai-code-tracking.db`의 대화 요약에서 보충(없으면 auto·파일 mtime) |
| Grok | `~/.grok/grok.db` + `~/.grok/logs/unified.jsonl` | grok-cli는 `usage_events` 테이블의 실제 토큰·비용(`cost_micros`)을 읽고, xAI Grok Build는 `logs/unified.jsonl`의 `shell.turn.inference_done`(`prompt_tokens`·`cached_prompt_tokens`·`completion_tokens`)을 합산. 로그가 없는 세션만 ACP `updates.jsonl`의 `_meta.totalTokens` 곡선에서 컴팩션 구간별 피크·턴별 증가량으로 **추정**. 표시되는 $는 공개 API 단가 추정이며 SuperGrok 주간 크레딧과 단위가 다름 |
| Claude 한도(5h/7d) | 자체 연결 계정 → `~/.gjc/agent/agent.db` → Claude Code 키체인/`~/.claude/.credentials.json` | `/api/oauth/usage`를 GET — 유효한 액세스 토큰을 위 순서로 찾아 첫 번째로 응답하는 토큰을 씁니다. 자체 연결 계정의 토큰만 앱이 직접 리프레시하고, CLI 토큰은 읽기 전용(리프레시 토큰은 회전되므로 건드리면 CLI 로그인이 깨질 수 있음). 전부 만료면 gjc 캐시 리포트로 폴백하고 UI에 "N시간 전 기준"을 표시합니다 |
| GPT 한도(5h/주간) | Codex CLI 롤아웃 로그의 `rate_limits` | ChatGPT 플랜 한도의 `used_percent`를 그대로 사용(프로바이더 공식 수치). Codex 실행 시에만 갱신되므로 오래되면 "N시간 전 기준"을 표시하고, 이미 초기화 시각이 지난 창은 버립니다 |
| Grok 한도(주간) | grok CLI OIDC 토큰 → `GET /v1/billing?format=credits` | SuperGrok 주간 크레딧의 `creditUsagePercent`(0…100). 월간 달러 미터(`/v1/billing`)는 구독 플랜에서 0이라 쓰지 않음. 세션(5h) 한도는 없음 |

비용·토큰은 로컬 로그에서 집계하지만 **한도 소진율은 로컬 로그로 재현할 수 없습니다** — 한도를 재는 단위가 달러가 아니고 플랜 상한도 디스크에 없기 때문입니다. 그래서 이 값만 프로바이더가 알려주는 수치를 그대로 씁니다. Claude 5h/7d 한도는 Anthropic 계정 단위로 공유되므로 Claude Code·GJC 연결 모두에 동일하게 적용되고, GPT 한도는 Codex 연결에, Grok 주간 크레딧은 Grok 연결에 적용됩니다. Gemini·Cursor는 읽을 수 있는 공식 한도가 없어 역대 기록 대비로만 표시합니다. Grok 팝오버의 주간 카드 큰 숫자는 크레딧 %이고, 로컬 $ 추정은 보조 설명으로만 붙습니다.

앱이 60초마다 집계해 `~/Library/Application Support/AI Labor Office/`에 `snapshot.json`(합산, 구버전 호환)과 `widget-data.json`(합산+소스별), `widget-config.json`(위젯 설정)을 저장하고, 위젯은 이 파일들만 읽습니다(샌드박스 read-only 예외). 계정을 연결하면 같은 폴더의 `oauth.json`(0600)에 자체 토큰이 저장됩니다. 이전 버전(`AIUsage/`)에 있던 데이터는 첫 실행 때 이 폴더로 이전됩니다.

## 빌드 & 설치

```sh
./build.sh          # build/AI Labor Office.app 생성 (ad-hoc 서명)
./build.sh install  # /Applications 에 설치 후 실행 + 위젯 등록 확인
./build.sh dmg      # assets/AI-노동청-<버전>.dmg 생성 (배포용)
```

요구 사항: macOS 14+, arm64, Xcode Command Line Tools.

위젯은 앱 첫 실행 후 데스크탑 우클릭 → **위젯 편집** 또는 알림 센터에서 "AI 노동청"으로 추가합니다.

> **번들 폴더명은 ASCII(`AI Labor Office.app`)여야 합니다.** 폴더명이 한글("AI 노동청.app")이면 ExtensionKit이 위젯 appex를 NFD로 분해된 URL로 LaunchServices에서 조회하다 실패해("not found in LS database") 위젯이 갤러리에 뜨지 않습니다. Finder에 보이는 한글 이름은 `ko.lproj/InfoPlist.strings`가 담당하고, 구버전 경로(`AIUsage.app` 등)로 설치된 앱은 실행 시 스스로 `AI Labor Office.app`으로 이사한 뒤 재시작합니다.

## 배포 (.dmg)

`./build.sh dmg`가 `Resources/App-Info.plist`의 `CFBundleShortVersionString`을 읽어 `assets/AI-노동청-<버전>.dmg`(로컬 보관용)와 `assets/AI-Labor-Office-<버전>.dmg`(릴리스 업로드용 ASCII 이름 — 한글 파일명은 GitHub이 지워버림)를 함께 만듭니다. DMG에는 앱과 `/Applications` 심링크가 들어 있어 드래그로 설치합니다. 빌드는 시작 전에 두 plist의 버전이 일치하는지 검사하고, 불일치면 아무것도 지우지 않고 실패합니다.

버전 업데이트 절차:

1. `Resources/App-Info.plist`와 `Resources/Widget-Info.plist`의 `CFBundleShortVersionString`·`CFBundleVersion`을 둘 다 같은 값으로 올린다 (불일치면 빌드가 실패한다).
2. `./build.sh dmg` 실행 → `assets/`에 한글·ASCII 두 파일이 추가된다 (기존 버전 파일은 그대로 유지).
3. 커밋 후 푸시하고, 앱 버전과 같은 태그로 릴리스를 만든다: `git tag v<버전> && git push origin main v<버전>` 후 `gh release create v<버전> assets/AI-Labor-Office-<버전>.dmg`. `.dmg` 에셋이 꼭 있어야 앱 내 업데이트가 동작한다.

앱은 실행 시(및 6시간마다) 최신 릴리스 태그를 확인해서, 현재 버전보다 높으면 DMG를 받아 스스로 교체하고 재시작합니다(`Sources/App/Updater.swift`). 자동 설치는 팝오버 설정에서 끌 수 있습니다.

> ad-hoc 서명이므로 다른 맥에서는 첫 실행 시 우클릭 → 열기(Gatekeeper 우회)가 필요합니다.

## 구조

```
Sources/
  Shared/   Models.swift(데이터 모델·포맷·스냅샷/위젯 설정 IO), Heatmap.swift(히트맵 캔버스),
            ProviderIcon.swift(Claude/GPT/Gemini/Cursor/Grok 글리프·링 게이지)
  App/      AIUsageApp.swift(NSStatusItem+NSPopover, 연결별 아이콘, ASCII 번들명 마이그레이션),
            Connections.swift(AI 연결 모델), PopoverView.swift, LifetimeStatsView.swift(전 기간 통계 창),
            UsageStore.swift(수집·집계 — GJC/Claude Code/Codex/Gemini/Cursor/Grok 로더),
            RateLimitProbe.swift(Claude 5h/7d 한도 조회),
            AccountAuth.swift(계정 연결·자체 OAuth 토큰),
            OAuthCallbackServer.swift(localhost:54545 로그인 콜백 수신),
            Updater.swift(GitHub 릴리스 자체 업데이트),
            LoginItem.swift(로그인 시 자동 실행 — SMAppService + LaunchAgent 폴백)
  Widget/   Widgets.swift(위젯 번들 4종, 앱에서 쓴 설정·소스별 스냅샷을 읽어 렌더)
Resources/  Info.plist 2종, widget.entitlements, AppIcon.icns(icon.png 기반)
build.sh    swiftc 직접 빌드 + codesign + 설치/DMG 패키징
assets/     배포용 버전별 DMG
icon.png    앱 아이콘 원본
```
