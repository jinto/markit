# Intent: macOS 네이티브 마크다운 에디터 (Markdowner 대응)

- Date: 2026-08-06
- Status: retroactive — spec.md/plan.md에서 2026-10-20 재구성
- Next: spec.md, plan-markdown-syntax-map.md, plan-document-core.md, plan-editor-kit.md, plan-app-shell.md

## Problem
사람은 워드프로세서처럼 편하게 편집하고 싶고, 코딩 에이전트(Claude Code, Codex)는 예측 가능한 깨끗한 마크다운 파일을 필요로 한다. AST를 재직렬화하는 WYSIWYG 에디터는 열었다 저장만 해도 서식을 정규화해 diff를 만들고, 같은 파일을 에이전트와 동시에 다루면 충돌·부분 기록·가짜 변경 알림이 생긴다. 참고 대상인 Markdowner는 웹 기술 기반 베타이고 미서명이라 설치 시 quarantine 해제를 요구한다.

## Proposed outcome
- 마커가 커서 밖에서 흐려지거나 숨는 WYSIWYG 편집과 소스/분할 모드를, 같은 원문 하나를 공유하는 표시 방식 전환으로 제공한다
- 파일은 언제나 깨끗한 마크다운: 열고 저장하면 바이트가 그대로다 (CRLF, 한글, 이모지, 후행 공백 포함)
- 에이전트가 파일을 고치면 버퍼가 clean일 때 자동 리로드되고, dirty일 때는 조용히 덮어쓰지 않고 사용자가 고른다
- 즉시 실행, 낮은 메모리, 시스템 통합을 갖춘 네이티브 macOS 앱. 서명·notarize로 배포한다
- 단계: v1 에디터 본질(3-모드, 열기/저장, 외부 변경·충돌 정책, 커맨드 팔레트, 라이브 스타일링) → v2 에이전트 통합(`mdner` CLI, `$EDITOR`/Ctrl+G, 내장 터미널) → v3 내보내기(PDF, self-contained HTML, 문서/워크스페이스)

## Affected users and systems
- 마크다운 문서를 코딩 에이전트와 함께 쓰는 macOS 사용자, 특히 한글 사용자 (한글 IME 조합이 핵심 품질 영역)
- 같은 파일을 읽고 쓰는 코딩 에이전트와 터미널 워크플로

## Constraints
- macOS 전용, 최소 macOS 14. 웹 기술(Electron/Tauri/WebView) 배제
- 프로젝트 라이선스 MIT. GPL 의존성 금지 (App Store 경로를 닫으므로). 런타임 의존성은 적고 퍼미시브·성숙해야 한다
- 원문이 진실: 재직렬화 금지. 스타일링은 원문을 바꾸지 않는다
- 저장은 원자적이어야 한다 — 에이전트가 부분 기록된 파일을 보면 안 되고, 실패 시 원본이 보존돼야 한다
- 잘못된 UTF-8 파일은 손상된 상태로 열지 않고 거부한다
- 핵심 스타일링 엔진은 직접 소유한다 (어린 서드파티 패키지를 앱 심부에 두지 않는다)

## Out of scope
- Windows/Linux, 실시간 협업, 클라우드 동기화, 계정
- 마크다운 외 포맷(docx, org-mode) 편집
- v1에서 표·이미지·코드블록의 "진짜 같은" 렌더링, 링크 URL 접기, 모드 기억 같은 영속 상태

## Open questions
- `$EDITOR`/Ctrl+G의 저장까지 블로킹 대기를 XPC로 할지 URL scheme + 종료 신호로 할지 (v2)
- 증분 재파싱 착수 시점 — 측정상 약 32KB(분할 모드는 약 16KB)가 손익분기점
- 한글에는 시스템 이탤릭·고정폭 폰트가 없어 강조와 인라인 코드 표시가 약하다. 한글 코딩 폰트 번들 여부는 v1 이후
- 숨긴 마커 위 캐럿 이동 절충이 실사용에서 견딜 만한지, 한글 IME·언두 동작 — 수동 검증으로만 확인 가능
