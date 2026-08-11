# 배포

`v` 로 시작하는 태그를 밀면 GitHub Actions가 서명·공증된 DMG를 만들어 릴리스에 올린다.

```
git tag v0.1.0
git push origin v0.1.0
```

태그를 만들지 않고 설정만 확인하려면 Actions에서 **Release** 워크플로를 수동 실행한다
(`workflow_dispatch`). 이 경로는 릴리스를 만들지 않고 DMG를 워크플로 아티팩트로만 올린다.
**서명 시크릿을 처음 넣은 뒤에는 이걸로 먼저 확인하는 것이 좋다** — 태그는 되돌리기 번거롭다.

## 로컬에서

```
scripts/make-app.sh 0.1.0        # dist/Markit.app
scripts/make-dmg.sh 0.1.0        # dist/Markit-0.1.0.dmg
```

서명까지 하려면 식별자를 준다:

```
CODESIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" scripts/make-app.sh 0.1.0
CODESIGN_IDENTITY="-" scripts/make-app.sh 0.1.0     # 애드혹 (로컬 확인용)
```

`security find-identity -v -p codesigning` 으로 쓸 수 있는 식별자를 볼 수 있다.

## Xcode 프로젝트를 쓰지 않는다

`Package.swift` 하나가 진실이고 모든 것이 `swift build`/`swift test`로 돌아간다.
앱 번들은 폴더 구조 + `Info.plist`일 뿐이므로 `scripts/make-app.sh`가 직접 조립한다.
프로젝트 파일을 하나 더 유지할 이유가 없고, 유지하면 타깃 정의가 두 곳에 생긴다.

빌드는 **유니버설(arm64 + x86_64)** 이다. 한쪽만 만들면 그 아키텍처가 아닌 사용자는
앱을 아예 실행할 수 없다.

## 필요한 시크릿

리포지터리 Settings → Secrets and variables → Actions 에 넣는다.

| 시크릿 | 무엇 |
|---|---|
| `DEVELOPER_ID_CERT_BASE64` | **Developer ID Application** 인증서 + 개인키를 담은 `.p12`를 base64로 인코딩한 문자열 |
| `DEVELOPER_ID_CERT_PASSWORD` | 그 `.p12`의 암호 |
| `APPLE_ID` | Apple 개발자 계정 이메일 |
| `APPLE_APP_PASSWORD` | 앱 암호 (계정 암호가 아니다) |
| `APPLE_TEAM_ID` | 10자 팀 ID |

### 인증서 종류를 반드시 확인한다

공증에는 **`Developer ID Application`** 인증서가 필요하다. 이름이 비슷한 다른 것들로는
안 된다:

| 인증서 | 용도 | 공증 |
|---|---|---|
| `Developer ID Application` | 앱 스토어 밖 배포 | **가능** |
| `Apple Distribution` | App Store / Ad Hoc | 불가 |
| `Apple Development` | 개발 중 로컬 실행 | 불가 |

워크플로는 키체인에서 `Developer ID Application`을 찾아 쓰고, 없으면 키체인에 실제로
들어 있는 목록을 찍으며 실패한다. 잘못된 인증서를 넣는 것이 흔한 실수이므로 일부러
분명하게 멈춘다.

### `.p12` 만들기

1. 키체인 접근에서 `Developer ID Application` 인증서를 찾는다
   (없으면 [developer.apple.com](https://developer.apple.com/account/resources/certificates)에서 만든다)
2. 인증서를 **개인키와 함께** 선택 → 우클릭 → 내보내기 → `.p12`
3. `base64 -i cert.p12 | pbcopy` 로 인코딩해 시크릿에 붙인다

### 앱 암호 만들기

[appleid.apple.com](https://appleid.apple.com) → 로그인 및 보안 → 앱 암호.
계정 암호를 넣으면 공증이 인증 오류로 실패한다.

## 파이프라인이 하는 일

1. `swift test` — 깨진 빌드를 배포하지 않는다
2. 시크릿의 `.p12`를 임시 키체인에 넣는다
   - `security set-key-partition-list`가 반드시 필요하다. 없으면 codesign이 개인키를
     못 읽어 `errSecInternalComponent`로 실패한다
3. 키체인에서 `Developer ID Application` 식별자를 찾는다 (하드코딩하지 않는다)
4. 유니버설 릴리스 빌드 → `Markit.app` 조립 → 하드닝된 런타임으로 서명
5. `notarytool submit --wait` → **`status`가 `Accepted`인지 확인** → `stapler staple`
   - `stapler validate`와 `spctl --assess`로 실제로 통과하는지 확인한다.
     이 확인을 건너뛰면 공증되지 않은 앱이 릴리스에 올라가고, 사용자에게는
     "손상되었기 때문에 열 수 없습니다"로 나타난다
6. `create-dmg`로 DMG를 만들고 **마운트해서 앱이 들어 있는지 확인**한다
7. 태그면 릴리스에 업로드, 수동 실행이면 아티팩트로 업로드

## 아직 없는 것

- **앱 아이콘.** `Resources/AppIcon.icns`를 두면 번들과 DMG 볼륨 아이콘에 자동으로
  들어간다. 없으면 기본 아이콘으로 나간다
- **자동 업데이트(Sparkle 등).** 지금은 사용자가 새 DMG를 직접 받아야 한다
- **앱 샌드박스.** 쓰지 않으므로 entitlements가 없다. 나중에 App Store로 가려면
  샌드박스가 필요한데, 그때 `FSEventsFileWatcher`가 **열린 파일의 부모 디렉터리를
  감시**하는 것이 문제가 된다 (사용자가 고른 파일 자체만 접근이 허용된다).
  원자적 쓰기가 inode를 바꾸기 때문에 부모 디렉터리를 봐야 하는 것이므로, 샌드박스로
  가려면 이 설계를 다시 봐야 한다
- **`.md` 파일 연결.** Finder에서 더블클릭으로 열 수 없다. `CFBundleDocumentTypes`를
  선언하는 것만으로는 안 되고 열기 이벤트를 처리하는 코드가 필요하다
