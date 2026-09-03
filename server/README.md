# 임대지기 계약서 판독 서버 (무료 구성)

앱(GitHub Pages)에서 찍은 계약서 사진을 이 서버가 받아 **Google Gemini(무료 티어)** 로 읽고,
보증금·임대료·면적·기간·임차인 등을 JSON으로 돌려줍니다. 서버는 **Cloudflare Workers 무료 플랜**에 올립니다.

| 구성 | 서비스 | 비용 | 무료 한도(2026년 기준, 변동 가능) |
|---|---|---|---|
| 화면 | GitHub Pages | 무료 | — |
| 서버 | Cloudflare Workers | 무료 플랜 | 하루 10만 요청 |
| AI 판독 | Google Gemini API (AI Studio 키) | 무료 티어, 카드 등록 불필요 | 분당 10~15회, 하루 250~1,500회 (모델별) |

신용카드 없이 전부 무료 범위에서 동작합니다. 사진은 판독 후 저장되지 않습니다.
(Gemini 무료 티어는 입력 데이터가 Google 서비스 개선에 사용될 수 있습니다. 실제 고객 계약서를 다루는 단계에서는 유료 티어 전환을 검토하세요.)

---

## 1단계. Gemini API 키 만들기 (3분)

1. https://aistudio.google.com 접속 → Google 계정 로그인
2. 왼쪽 메뉴 **Get API key** → **Create API key** → 프로젝트 새로 만들기 선택
3. `AIza…` 로 시작하는 키를 복사해 둡니다. (다른 곳에 붙여 넣지 말고 3단계에서만 사용)

## 2단계. Cloudflare Worker 만들기 (5분, 설치 프로그램 없음)

1. https://dash.cloudflare.com 접속 → 무료 회원가입/로그인
2. 왼쪽 메뉴 **Workers & Pages** → **Create** → **Create Worker**
3. 이름을 `rentkeeper-extract` 로 바꾸고 **Deploy** (기본 Hello World가 배포됩니다)
4. **Edit code** 를 눌러 편집기를 열고, 기존 내용을 모두 지운 뒤 이 폴더의 **`worker.js` 내용 전체를 붙여 넣기** → 오른쪽 위 **Deploy**
5. 편집기를 닫고 Worker 화면의 **Settings → Variables and Secrets** 에서 추가:
   - `GEMINI_API_KEY` — 유형 **Secret** — 1단계에서 복사한 키
   - `ALLOWED_ORIGINS` — 유형 Text — `https://jssong-hub.github.io`
     (테스트 중 다른 주소에서도 열려면 일단 비워 두고, 공개 후 꼭 지정)
   - (선택) `APP_TOKEN` — Secret — 아무 비밀번호. 지정하면 앱 설정의 "서버 비밀번호"에 같은 값을 넣어야 동작
   - (선택) `GEMINI_MODEL` — Text — 기본 `gemini-2.5-flash`. 무료 한도가 부족하면 `gemini-2.0-flash` 또는 `gemini-2.5-flash-lite`
6. **Save and deploy**. Worker 화면 상단의 주소 `https://rentkeeper-extract.<계정이름>.workers.dev` 를 복사합니다.
   - 브라우저로 그 주소를 열면 `{"ok":true,"service":"rentkeeper-extract",...}` 가 보이면 정상입니다.

## 3단계. 앱에 서버 주소 넣기 (1분)

폰에서 임대지기 열기 → 오른쪽 위 ⚙ 설정 → **계약서 자동 판독 (AI)** →
**판독 서버 주소** 에 2단계 주소 붙여 넣기 → **서버 연결 확인** 에 "연결됨"이 뜨면 **저장**.

이후 **계약 추가 → 카메라로 촬영 → 🤖 AI로 판독해서 등록** 을 누르면
사진이 서버를 거쳐 판독되고 임대현황에 자동 등록됩니다.

---

## 문제 해결

- **"허용되지 않은 출처입니다"** → `ALLOWED_ORIGINS` 값이 앱 주소와 다릅니다. `https://jssong-hub.github.io` (끝에 `/` 없이) 로 맞추거나 비워 두세요.
- **"무료 사용량을 잠시 초과했습니다"** → Gemini 무료 티어의 분당 한도입니다. 1분 후 다시 시도하거나 `GEMINI_MODEL` 을 `gemini-2.0-flash` 로 바꾸세요.
- **"서버에 GEMINI_API_KEY가 설정되지 않았습니다"** → Secret 저장 후 **Deploy** 를 다시 눌렀는지 확인.
- **연결 실패** → 주소 오타(https 포함, 끝 `/` 제외) 확인. Worker 화면 → Logs 에서 실시간 오류를 볼 수 있습니다.

## 명령줄(선택) 배포

Node.js가 있으면 이 폴더에서:

```bash
npx wrangler login
npx wrangler secret put GEMINI_API_KEY
npx wrangler deploy
```

## 동작 구조

```
폰 브라우저(GitHub Pages)  --사진(base64)-->  Cloudflare Worker  --사진+지시문-->  Gemini API
                          <--계약 정보 JSON--                     <--JSON--
```

키는 Worker 안에만 있고 앱 코드·폰에는 없습니다. 앱은 서버 주소만 알면 됩니다.
