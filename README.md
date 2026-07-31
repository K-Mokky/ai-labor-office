# AI 노동청

내 AI가 노동착취를 얼마나 당했는지 확인할 수 있는 앱. Claude/GJC 사용량을 보여주는 macOS 메뉴바 앱 + WidgetKit 위젯이며, Xcode 프로젝트 없이 `swiftc`로 빌드합니다.

## 기능

- **AI 연결**: 첫 실행 시 연결 메뉴가 자동으로 열립니다. Claude Code·GJC 중 원하는 소스를 연결하고, 연결할 때 아이콘 색을 고를 수 있습니다(기본 민트). 연결 관리(추가/해제)는 팝오버의 "AI 연결" 섹션에 항상 있습니다.
- **메뉴바**: 연결한 AI마다 아이콘이 하나씩 생깁니다. 각 아이콘은 프로바이더 글리프(Claude/GPT 자동 감지)가 해당 AI의 사용률만큼 아래에서 위로 채워지는 게이지입니다(100% = 완전히 채워진 아이콘).
- **아이콘 설정**: 아이콘별로 채움 기준(세션/오늘/주간 사용량)과 색을 팝오버에서 변경할 수 있습니다.
- **사용률(%) 기준**: 세션·주간은 **Anthropic이 실제 적용하는 5시간·7일 한도**(100% = 한도 소진)를 그대로 씁니다. 한도를 읽지 못할 때만 역대 최대 기록 대비로 되돌아가고, 오늘은 항상 최고 일간 대비입니다.
- **팝오버**: 아이콘을 클릭하면 해당 AI의 통계가 열립니다 — 요약 카드(세션·주간 링 게이지에 한도 소진율과 초기화까지 남은 시간), 모델별 사용량 바, 깃허브 스타일 기여 히트맵, 아이콘 설정, AI 연결 관리
- **위젯 4종**: 기여 그래프(중/대), 요약(소/중), 모델별(소/중), 세션 링 게이지(소) — 연결된 모든 AI의 합산 기준

## 데이터 소스

| 소스 | 경로 | 방식 |
|---|---|---|
| GJC | `~/.gjc/stats.db` | SQLite `messages` 테이블 (임시 복사 후 읽기) |
| Claude Code | `~/.claude/projects/**/*.jsonl` | assistant 메시지 usage 파싱, `costUSD` 없으면 공개 단가로 추정 |
| 실제 한도(5h/7d) | `~/.gjc/agent/agent.db` | `cache`에 캐시된 `/api/oauth/usage` 리포트를 읽고, 저장된 액세스 토큰이 아직 유효하면 같은 엔드포인트를 GET으로 갱신 (읽기 전용 — DB에 쓰지 않고 리프레시 토큰도 건드리지 않음) |

비용·토큰은 로컬 로그에서 집계하지만 **한도 소진율은 로컬 로그로 재현할 수 없습니다** — 한도를 재는 단위가 달러가 아니고 플랜 상한도 디스크에 없기 때문입니다. 그래서 이 값만 프로바이더가 알려주는 수치를 그대로 씁니다. 5h/7d 한도는 Anthropic 계정 단위로 공유되므로 Claude Code·GJC 연결 모두에 동일하게 적용됩니다.

앱이 60초마다 집계해 `~/Library/Application Support/AIUsage/snapshot.json`에 저장하고, 위젯은 이 파일만 읽습니다(샌드박스 read-only 예외).

## 빌드 & 설치

```sh
./build.sh          # build/AI 노동청.app 생성 (ad-hoc 서명)
./build.sh install  # /Applications 에 설치 후 실행 + 위젯 등록 확인
./build.sh dmg      # assets/AI-노동청-<버전>.dmg 생성 (배포용)
```

요구 사항: macOS 14+, arm64, Xcode Command Line Tools.

위젯은 앱 첫 실행 후 데스크탑 우클릭 → **위젯 편집** 또는 알림 센터에서 "AI 노동청"으로 추가합니다.

## 배포 (.dmg)

`./build.sh dmg`가 `Resources/App-Info.plist`의 `CFBundleShortVersionString`을 읽어 `assets/AI-노동청-<버전>.dmg`를 만듭니다. DMG에는 앱과 `/Applications` 심링크가 들어 있어 드래그로 설치합니다.

버전 업데이트 절차:

1. `Resources/App-Info.plist`와 `Resources/Widget-Info.plist`의 `CFBundleShortVersionString`(필요시 `CFBundleVersion`)을 올린다.
2. `./build.sh dmg` 실행 → `assets/`에 새 버전 파일이 추가된다 (기존 버전 파일은 그대로 유지).
3. 커밋 후 푸시하고, 앱 버전과 같은 태그로 릴리스를 만든다: `git tag v<버전> && git push origin v<버전>` 후 `gh release create v<버전> <dmg>`. 릴리스 에셋 파일명은 ASCII로 올린다(한글은 GitHub이 지워버림). `.dmg` 에셋이 꼭 있어야 앱 내 업데이트가 동작한다.

앱은 실행 시(및 6시간마다) 최신 릴리스 태그를 확인해서, 현재 버전보다 높으면 DMG를 받아 스스로 교체하고 재시작합니다(`Sources/App/Updater.swift`). 자동 설치는 팝오버 설정에서 끌 수 있습니다.

> ad-hoc 서명이므로 다른 맥에서는 첫 실행 시 우클릭 → 열기(Gatekeeper 우회)가 필요합니다.

## 구조

```
Sources/
  Shared/   Models.swift(데이터 모델·포맷·스냅샷 IO), Heatmap.swift(히트맵 캔버스)
  App/      AIUsageApp.swift(NSStatusItem+NSPopover, 연결별 아이콘), Connections.swift(AI 연결 모델),
            PopoverView.swift, UsageStore.swift(수집·집계), Updater.swift(GitHub 릴리스 자체 업데이트)
  Widget/   Widgets.swift(위젯 번들 4종)
Resources/  Info.plist 2종, widget.entitlements, AppIcon.icns(icon.png 기반)
build.sh    swiftc 직접 빌드 + codesign + 설치/DMG 패키징
assets/     배포용 버전별 DMG
icon.png    앱 아이콘 원본
```
