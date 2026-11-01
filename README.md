# 맥북 배터리 제어

메뉴 막대에서 MacBook 배터리 상태와 충전 한도를 보고, CPU·메모리·저장공간·네트워크를 함께 확인하는 macOS 앱입니다. 현재 버전은 1.0.3이며, macOS 13 이상의 Apple Silicon Mac에서 동작합니다.

Dock에 상주하지 않는 메뉴 막대 앱으로, 충전 한도를 직접 바꾸고 배터리 잔량을 일정 범위에 두거나 한 번만 100%까지 충전할 수 있습니다. 메뉴 막대에는 배터리 숫자와 함께 CPU 사용량에 맞춰 속도가 바뀌는 캐릭터가 표시됩니다.

기능과 구현을 이어서 보려면 [기술소개서](기술소개서.md)를 보면 됩니다. 버전별 수정 내용은 [릴리스](https://github.com/SonSucheol/macbook-battery-control/releases)에 있습니다.

## 기능

- 충전 한도를 80%, 85%, 90%, 95%, 100% 중에서 바꿉니다. 100%는 제한 해제입니다.
- 한 번만 100%까지 충전한 뒤 이전 한도로 되돌립니다.
- 하한과 상한을 정해 잔량이 그 범위를 벗어나면 충전 한도를 다시 맞춥니다.
- 보정 모드에서는 한도를 100%로 올리고, 사용자가 끝내면 이전 한도로 돌아갑니다.
- 메뉴 막대와 상태창에서 잔량, 충전 상태, 건강도, 사이클, 전력, 온도를 보여 줍니다.
- CPU, 메모리, 저장공간, 네트워크 사용량을 상태창과 선택적 지표 막대에 표시합니다.
- 외부 JSON 파일을 사용자 지표로 읽어 상태창과 메뉴 막대에 넣습니다.
- 기본 캐릭터 외에 이미지 묶음을 러너로 추가할 수 있습니다.
- Control–Option–1부터 5까지로 충전 한도를 바꾸고, 설정 창 단축키는 바꿀 수 있습니다.
- 로그인 시 실행을 켤 수 있습니다.

## 기술

| 영역 | 사용 |
| --- | --- |
| 언어·UI | Objective-C, Cocoa, 메뉴 막대 상태 항목, 설정 창, 팝오버 |
| 충전 한도 | 시스템 PowerUI의 `PowerUISmartChargeClient` |
| 배터리 | `pmset`, `ioreg`의 AppleSmartBattery |
| CPU·메모리 | `host_statistics`, `host_statistics64` |
| 저장공간·네트워크 | 볼륨 URL, `getifaddrs`, System Configuration |
| 실행·단축키 | `SMAppService`, Carbon 전역 단축키 |
| 배포 | arm64 앱 번들, `pkgbuild` / `productbuild` |

외부 라이브러리는 쓰지 않습니다. 화면과 제어 로직은 `menubar.m` 한 파일에 있습니다.

## 요구 사항

- macOS 13 이상, Apple Silicon
- 충전 한도 변경은 해당 기능을 지원하는 MacBook에서만 동작합니다
- 관리자 권한이 필요한 설치 패키지로 응용 프로그램 폴더에 넣을 수 있습니다

## 빌드

앱 번들을 만든 뒤 아래처럼 컴파일합니다. 이미지 리소스는 `assets/character`에 있습니다.

```bash
xcrun clang -fobjc-arc -Wall -Wno-deprecated-declarations \
  -framework Cocoa -framework ServiceManagement -framework Carbon \
  -framework SystemConfiguration -framework ImageIO -framework UniformTypeIdentifiers \
  menubar.m -o "맥북 배터리 제어.app/Contents/MacOS/MacBookBattery"
codesign --force --deep --sign - "맥북 배터리 제어.app"
```

설치 패키지는 저장소에 포함하지 않습니다. 릴리스에는 패치 내역만 있습니다.

## 저장소 구성

| 경로 | 내용 |
| --- | --- |
| `menubar.m` | 배포 중인 메뉴 막대 앱 |
| `Info.plist` | 번들 ID, 버전, 메뉴 막대 전용 설정 |
| `assets/character` | 기본 러너 프레임 |
| `build/distribution.xml`, `build/installer` | 설치 패키지 안내 문구 |
| `app.py`, `battery_helper.m` | 메뉴 막대 앱 이전의 로컬 웹 화면 시안 |

`app.py`는 `127.0.0.1`에서만 배터리 화면을 띄우던 초기 구현입니다. 현재 앱은 그 경로를 쓰지 않습니다.
