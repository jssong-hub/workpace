# 임대지기 백엔드 — Supabase(서울) + AI 판독

앱(GitHub Pages)에서 찍은 계약서 사진을 **Supabase Edge Function**(서울 리전)이 받아 AI로 읽고,
임대현황 등록에 필요한 항목을 돌려줍니다. 이 Supabase 프로젝트가 이후 **고객 로그인·데이터 저장(DB)·회사 접수**까지 맡는 단일 백엔드입니다.

판독 엔진은 비밀값만 바꿔 교체합니다(코드 수정 없음).

| 단계 | 판독 엔진 | 비용 | 비고 |
|---|---|---|---|
| **데모(지금)** | Google Gemini 무료 티어 | **0원**, 카드 불필요 | 분당 10~15건·하루 수백 건 한도. 입력 데이터가 Google 서비스 개선에 쓰일 수 있음 → 테스트용 계약서만 |
| 실서비스 | Upstage Information Extract(국내) | 페이지당 약 55원 | 초당 10건, 실제 고객 계약서 단계에서 전환 |

| 구성 | 서비스 | 비용(데모) |
|---|---|---|
| 화면 | GitHub Pages | 무료 |
| 서버·DB·로그인·파일 | Supabase (회사 기존 계정, 서울) | 무료 플랜 / 기존 요금제 |
| 판독 | Gemini 무료 티어 | 무료 |

---

## 1단계. 판독 키 (데모: Gemini, 무료)

1. https://aistudio.google.com/api-keys → **API 키 만들기** → 새 프로젝트 → `AIza…` 키 복사
   (실서비스 전환 시: https://console.upstage.ai 에서 `up_…` 키를 발급해 `UPSTAGE_API_KEY`로 등록하면 자동으로 Upstage가 사용됩니다)

## 2단계. Supabase 프로젝트 (5분)

1. https://supabase.com/dashboard 회사 계정으로 로그인 → 회사 조직(Organization) 선택
2. **New project**:
   - Name: `rentkeeper`
   - Database Password: 아무 강한 비밀번호 (메모해 두기 — 나중에 DB 직접 접속 시 필요)
   - Region: **Northeast Asia (Seoul)**
   - Plan: Free
3. 1~2분 뒤 프로젝트 화면이 열리면 완료

## 3단계. 판독 함수 올리기 (5분, 설치 프로그램 없음)

1. 왼쪽 메뉴 **Edge Functions** → **Deploy a new function** → **Via Editor**
2. Function name: `extract-contract`
3. 편집기의 기본 코드를 모두 지우고 `functions/extract-contract/index.ts` 내용 전체를 붙여 넣기 → **Deploy**
4. 함수 목록에서 `extract-contract` 클릭 → **Details** 탭에서
   - **Verify JWT with legacy secret** (또는 "Enforce JWT verification") 을 **끄기(OFF)** — 로그인 도입 전이므로
   - **Function URL** 복사: `https://<프로젝트ID>.supabase.co/functions/v1/extract-contract`
5. 왼쪽 메뉴 **Edge Functions → Secrets** (또는 Project Settings → Edge Functions) 에 추가:
   - `GEMINI_API_KEY` = 1단계 키  (실서비스: `UPSTAGE_API_KEY`)
   - `ALLOWED_ORIGINS` = `https://jssong-hub.github.io`
6. 브라우저로 Function URL을 열어 `{"ok":true,"service":"rentkeeper-extract","engine":"gemini"}` 가 보이면 정상

## 4단계. 앱에 주소 넣기 (운영자 1회)

`rentkeeper/index.html`, `임대지기/index.html` 의 아래 줄에 4번의 Function URL을 넣고 푸시합니다.

```js
const EXTRACT_SERVER = 'https://<프로젝트ID>.supabase.co/functions/v1/extract-contract';
```

**임대인은 아무 설정도 하지 않습니다.** 계약 추가 → 촬영 → ✨ 판독해서 등록.

---

## 다음 단계에서 같은 프로젝트에 붙일 것

- **Authentication**: 이메일/휴대폰 인증번호/카카오 로그인 (대시보드에서 켜기만 하면 됨)
- **Database**: `landlords`, `properties`, `contracts`, `rent_payments`, `invoices`, `submissions`(회사 접수) 테이블 + RLS(임대인은 자기 행만, 회사 직원은 전체)
- **Storage**: 계약서 사진 원본 버킷 (임대인별 폴더, RLS)
- 함수의 `verify_jwt` 를 켜서 로그인 사용자만 판독 호출 가능하게 전환
- 회사용 접수 대시보드(간단한 웹) — 초기에는 Supabase Table Editor로 대체 가능

## 문제 해결

- **허용되지 않은 출처입니다** → `ALLOWED_ORIGINS` 값을 `https://jssong-hub.github.io`(끝 `/` 없이)로. 테스트 중엔 비워도 됨
- **서버에 판독 키가 설정되지 않았습니다** → Secrets 저장 후 함수를 다시 Deploy
- **무료 사용량을 잠시 초과했습니다** → Gemini 무료 티어 분당 한도. 1분 후 재시도. `GEMINI_MODEL`을 `gemini-2.0-flash`로 바꾸면 한도가 다름
- **401 Unauthorized** → 3-4의 JWT 검증이 켜져 있음. 끄기
- **판독 서비스가 혼잡합니다** → Upstage 초당 한도. 자동 재시도 후에도 실패한 경우. 사용량이 늘면 Upstage Tier 상향
- **무료 프로젝트가 잠들었다(paused)** → Supabase 대시보드에서 Restore. 7일 미접속 시 발생. 실서비스는 Pro 플랜
- 실시간 오류는 Edge Functions → `extract-contract` → **Logs** 에서 확인
