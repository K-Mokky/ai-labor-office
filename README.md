# AI Usage

Claude/GJC 사용량을 보여주는 macOS 메뉴바 앱 + WidgetKit 위젯. Xcode 프로젝트 없이 `swiftc`로 빌드합니다.

## 기능

- **메뉴바**: 프로바이더 아이콘(Claude/GPT 자동 감지) + 선택한 지표(세션/전체/오늘/주간/모델별)를 사용률(%, 기본)·비용($)·토큰 단위로 상시 표시. 사용률은 원형 링 게이지로 표시(100% = 꽉 찬 원)
- **사용률(%) 기준**: 역대 최대 기록 대비 — 세션은 역대 최대 5시간 블록, 오늘은 최고 일간, 주간은 최고 7일, 모델은 전체 중 비중
- **팝오버**: 요약 카드(세션 링 게이지 포함), 모델별 사용량 바, 깃허브 스타일 기여 히트맵, 표시 설정
- **위젯 4종**: 기여 그래프(중/대), 요약(소/중), 모델별(소/중), 세션 링 게이지(소)

## 데이터 소스

| 소스 | 경로 | 방식 |
|---|---|---|
| GJC | `~/.gjc/stats.db` | SQLite `messages` 테이블 (임시 복사 후 읽기) |
| Claude Code | `~/.claude/projects/**/*.jsonl` | assistant 메시지 usage 파싱, `costUSD` 없으면 공개 단가로 추정 |

앱이 60초마다 집계해 `~/Library/Application Support/AIUsage/snapshot.json`에 저장하고, 위젯은 이 파일만 읽습니다(샌드박스 read-only 예외).

## 빌드 & 설치

```sh
./build.sh          # build/AI Usage.app 생성 (ad-hoc 서명)
./build.sh install  # /Applications 에 설치 후 실행 + 위젯 등록 확인
./build.sh dmg      # assets/AI-Usage-<버전>.dmg 생성 (배포용)
```

요구 사항: macOS 14+, arm64, Xcode Command Line Tools.

위젯은 앱 첫 실행 후 데스크탑 우클릭 → **위젯 편집** 또는 알림 센터에서 "AI Usage"로 추가합니다.

## 배포 (.dmg)

`./build.sh dmg`가 `Resources/App-Info.plist`의 `CFBundleShortVersionString`을 읽어 `assets/AI-Usage-<버전>.dmg`를 만듭니다. DMG에는 앱과 `/Applications` 심링크가 들어 있어 드래그로 설치합니다.

버전 업데이트 절차:

1. `Resources/App-Info.plist`와 `Resources/Widget-Info.plist`의 `CFBundleShortVersionString`(필요시 `CFBundleVersion`)을 올린다.
2. `./build.sh dmg` 실행 → `assets/`에 새 버전 파일이 추가된다 (기존 버전 파일은 그대로 유지).
3. 커밋 후 푸시하면 GitHub에서 바로 내려받을 수 있다.

> ad-hoc 서명이므로 다른 맥에서는 첫 실행 시 우클릭 → 열기(Gatekeeper 우회)가 필요합니다.

## 구조

```
Sources/
  Shared/   Models.swift(데이터 모델·포맷·스냅샷 IO), Heatmap.swift(히트맵 캔버스)
  App/      AIUsageApp.swift(MenuBarExtra), PopoverView.swift, UsageStore.swift(수집·집계)
  Widget/   Widgets.swift(위젯 번들 4종)
Resources/  Info.plist 2종, widget.entitlements, AppIcon.icns(하늘색 스타버스트)
build.sh    swiftc 직접 빌드 + codesign + 설치/DMG 패키징
assets/     배포용 버전별 DMG
```
