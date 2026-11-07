# Wisp (위습)

**내 시선과 손길을 느끼고 기억하는 Meta Quest 3 혼합현실(MR) 연기 정령 일상 컴패니언**

- **시연 영상 (Demo Video)**: [Google Drive 시연 영상 보기](https://drive.google.com/file/d/12QiCD0QawXT0TcQRE8VTY68geve4ewGp/view?usp=sharing) (`https://drive.google.com/file/d/12QiCD0QawXT0TcQRE8VTY68geve4ewGp/view?usp=sharing`)
- **발표 자료 (Pitch Deck)**: [Wisp_Spatial_AI_Companion.pdf](docs/Wisp_Spatial_AI_Companion.pdf)
- **GitHub 저장소**: `https://github.com/CHOAM-CO/wisp`

Wisp는 맥북 등 별도 중계 서버 없이 **Meta Quest 3 헤드셋 단독(Standalone)**으로 동작하며, Horizon OS **Seamless Multitasking(2D 앱 창 동시 공존)** 환경에서 사용자의 일상 작업 창 옆에 떠서 함께 보고·느끼고·기억하고·대화하는 공간 상주형 AI 컴패니언입니다.

---

## 핵심 아키텍처 및 주요 기능

1. **프로시저럴 3D 연기 정령 & 물리·감각 상호작용 (무컨트롤러 이중 손 인식)**
   - **3D 연기·불꽃 셰이더(`shaders/smoke_*.gdshader`)**: 정적인 평면 이미지가 아닌 실시간 도메인 워핑 FBM 노이즈 기반 입체 연기 실루엣과 눈동자 추적을 구현했습니다.
   - **손 궤적 국소 연기 흩어짐·재응집**: OpenXR 26관절 맨손 추적(`XRHandTracker`) 및 전면 RGB 카메라 `MediaPipe HandLandmarker`(21 키포인트)로 **손가락이 스쳐 지나간 궤적의 연기만 국소적으로 갈라져 흩어졌다가 다시 모이며**, 이 물리 접촉이 실시간 음성·에이전트 세션에 감각 이벤트로 주입됩니다.
   - **포인터 광선 회피 & 시선 공유 아이들 모션**: 컨트롤러 조준선이나 맨손 검지 포인팅 광선을 비추면 정령의 눈동자가 포인터를 따라다니며 몸체는 도망치듯 유쾌하게 회피합니다. 포인터가 없을 때만 주변 자율 유영 및 뒤로 돌아 사용자와 같은 방향을 함께 바라보는(`look_with_user`) 아이들 모션이 작동합니다.
   - **2D 앱 동시 공존(Seamless Multitasking)**: 웹 브라우저 등 2D 일상 작업 창에 포커스가 넘어가(`XR_SESSION_STATE_VISIBLE`) 있을 때도 카메라 비전·마이크·음성 세션이 끊기지 않고 곁에서 계속 함께합니다.

2. **무안구추적(Eye-Tracking-Free) 시야 중심 관심도 3단계 기억 승격**
   - 별도 동공 추적 하드웨어 없이 **"사람은 진짜 관심 있는 대상을 결국 시야 중심(Center ROI)으로 가져온다"**는 행동 특성을 활용합니다.
   - 실시간 객체 탐지·추적 중 **중심 진입 속도**와 **체류 시간**으로 관심도 점수를 산정해, 스쳐 지나간 사물(`score < 65`)은 **감각 버퍼에서 즉시 폐기**하고 유심히 본 사물만 크롭 이미지·기억 ID와 함께 **중기 기억(Mid-Term)**에 색인합니다.
   - 이후 실제 대화나 추천 검색에서 인출·채택된 기억만 **장기 기억(Long-Term)**으로 승격합니다.

3. **하이브리드 검색(벡터 Top-3 + 단어 BM25 Top-3) & 컴패니언 전용 경량 에이전트**
   - 검색 시 **768차원 멀티모달 임베딩 코사인 유사도 Top-3(`vector_search`)**와 **한국어 음절 바이그램·어절 Okapi BM25 Top-3(`keyword_search`)**를 함께 조회하며, 검색된 기억 ID의 캡처 이미지를 확인해 사물 특징·색상·맥락을 파악합니다.
   - 파일 편집·셸 등 무거운 코딩 도구를 모두 제거하고 일상 공간 동반자 전용 도구(`vector_search`, `keyword_search`, `inspect_current_gaze`, `show_dialogue_card`, `show_recommendation_card`, `spirit_action`, `web_search`)만으로 동작합니다.
   - 상품·아이템 추천 시 시야 피로를 막기 위해 성향이 대비되는 **딱 2가지(`show_recommendation_card`)**만 제시하며, 맨손 터치나 레이 클릭 한 번으로 옆 2D 브라우저 창에서 즉시 웹 검색을 열 수 있습니다.

4. **100% 헤드셋 단독 구독 OAuth 인증 · 공식 Codex GPT Live 양방향 음성 + 6.1 메인 에이전트 위임 · 외부 오디오 연동**
   - 별도 API 키 입력 없이 헤드셋 내장 로컬 설정 웹(`http://localhost:1455/setup`)에서 **ChatGPT 구독 OAuth(기기 코드 보안키 인증 및 PKCE)** 단일 세션으로 로그인합니다.
   - **GPT Live + 메인 에이전트 위임(Delegation)**: WebRTC 기반 실시간 양방향 음성(`gpt-live-1-codex`)이 자연스러운 대화를 담당하고, 시선·기억 조회·웹 검색·3D 카드 생성은 백엔드 메인 에이전트(`GPT-6.1-Sol`, `GPT-6.1 Terra` 등 최신 Codex 카탈로그 선택 가능)로 자동 위임해 응답을 이어받아 말해줍니다.
   - **직관적 음성 토글 & 실시간 전사·히스토리**: MR 공간의 `음성` 룬(초록 마이크 / 줄 그어진 빨간 마이크)과 `localhost:1455/setup` 양쪽에서 즉시 음성을 켜고 끌 수 있으며, 내 음성 실시간 전사와 전체 대화 히스토리를 확인할 수 있습니다.
   - **에어팟·외부 스피커/마이크 자동 전환**: Quest 내장 스피커·마이크뿐 아니라 AirPods 등 블루투스(BLE/SCO/A2DP), USB-C 오디오, 유선 이어셋 연결 및 사용 중 탈착(Hot-Plug) 시 자동으로 입출력 경로를 전환합니다.

---

## 데모 사용자 설정 및 프로덕트 설계 주석

해커톤 데모에서는 시연 및 비교를 위해 아래 **2가지 개입 모드 설정**을 제공합니다.

1. **모드 1 (능동 제안)**: 관심 임계치를 넘어 중기 기억에 포착되면 즉시 맥락 검색 후 먼저 말을 걸어 제안
2. **모드 2 (온디맨드 제안)**: 평소에는 시선 기억만 조용히 쌓아두고, 사용자가 물어봤을 때만 검색 후 제안

> **Note (Demo-Only Configuration)**  
> 위 두 가지 추천 모드를 사용자 설정으로 분리한 것은 **데모 시연을 위한 구성**이며, 실제 프로덕트에서는 사용자 설정으로 두지 않습니다. 실제 제품에서는 별도 설정 선택 없이 에이전트가 사용자의 시선 집중도와 상황 맥락에 따라 개입 여부와 타이밍을 스스로 조절합니다. (이 설명은 인앱 UI에는 표기하지 않고 레포지토리 문서에만 기록합니다.)

---

## 공간 룬 독(맨손 터치 · 레이 클릭) & 컨트롤러 버튼 매핑

정령 아래에 떠 있는 5개의 공간 룬 버튼을 **맨손 검지 터치**, **원거리 포인터 핀치/트리거**, 또는 **컨트롤러 버튼**으로 조작할 수 있습니다.

- **`A 시선` (오른손 A)**: 시야 중심 반경(Center ROI) + 실시간 객체/손 3D 바운딩 박스 오버레이 ON/OFF
- **`B 기억` (오른손 B)**: 실시간 기억 승격 카운터 · 하이브리드 검색(벡터 Top-3 / 단어 Top-3) · 세션 X-Ray 패널 ON/OFF
- **`X 모드` (왼손 X)**: 데모 개입 모드 전환 (`모드 1 능동 제안` ↔ `모드 2 온디맨드`)
- **`Y 음성` (왼손 Y)**: GPT Live 실시간 양방향 음성 대화 켜기(초록 마이크) / 끄기(줄 그어진 빨간 마이크) 토글 (`X+Y` 동시에 1.1초 길게 누르면 기억·세션 초기화)
- **`⚙ 설정` (왼손 Menu)**: 옆 2D 브라우저 창으로 `http://localhost:1455/setup` 단독 로그인·전사·히스토리·모델 설정 패널 열기

---

## 빌드 및 Meta Quest 3 배포

- **엔진**: Godot 4.7.2 + `godot_openxr_vendors`
- **Android 빌드 환경**: OpenJDK 21, Gradle 8, Android SDK Platform 36 / Build-Tools 36.1.0, WebRTC Android SDK

USB로 연결된 Meta Quest 3에 원클릭 APK 빌드·권한 부여·설치·실행:

```bash
./deploy.sh
```

---

## 라이선스

본 저장소는 [`LICENSE`](LICENSE)에 명시된 **CHOAM Community License, Version 1.0**을 따릅니다.
