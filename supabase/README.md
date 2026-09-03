# 임대지기 백엔드 — Supabase(서울) + Upstage(국내 문서판독)

앱(GitHub Pages)에서 찍은 계약서 사진을 **Supabase Edge Function**(서울 리전)이 받아
**Upstage Information Extract**(국내 기업의 문서 항목 추출 AI)로 읽고, 임대현황 등록에 필요한 항목을 돌려줍니다.
이 Supabase 프로젝트는 이후 **고객 로그인·데이터 저장·회사 접수 대시보드**에 그대로 이어서 쓰는 단일 백엔드입니다.

| 구성 | 서비스 | 위치 | 비용 |
|---|---|---|---|
| 화면 | GitHub Pages | — | 무료 |
| 서버·DB·로그인·파일 | Supabase | **서울** | 무료 플랜(테스트) → Pro 월 $25(실서비스) |
| 사진 판독 | Upstage Information Extract | 국내 기업(서버 위치는 계약 시 확인) | 페이지당 $0.04 (약 55원), 카드 등록 필요 |

계약서 1건(2~3장) 판독 ≈ 110~170원. 임대인 1,000명 × 계약 3건 = 약 3,000장 ≈ $120(1회성).
Upstage 기본 등급은 **초당 10건**(Tier 1) → 시간당 3만 6천 건. 동시접속이 몰려 한도에 걸리면 서버가 자동으로 잠시 기다려 재시도합니다.

> Upstage 무료 크레딧 제공 여부와 데이터 보관 정책은 가입 시 콘솔·약관에서 원문 확인이 필요합니다.
> (공개 페이지에는 데이터 보관·서버 위치가 명시되어 있지 않았습니다.)

---

## 1단계. Upstage API 키 (5분)

1. https://console.upstage.ai 접속 → 가입(Google 계정 가능)
2. 결제 수단 등록(신용카드) — 사용한 만큼만 과금
3. **API Keys** 메뉴 → **Create new key** → `up_…` 로 시작하는 키 복사

## 2단계. Supabase 프로젝트 (5분)

1. https://supabase.com → **Start your project** → GitHub 계정으로 로그인
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
   - `UPSTAGE_API_KEY` = 1단계 키
   - `ALLOWED_ORIGINS` = `https://jssong-hub.github.io`
6. 브라우저로 Function URL을 열어 `{"ok":true,"service":"rentkeeper-extract",...}` 가 보이면 정상

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
- **서버에 UPSTAGE_API_KEY가 설정되지 않았습니다** → Secrets 저장 후 함수를 다시 Deploy
- **401 Unauthorized** → 3-4의 JWT 검증이 켜져 있음. 끄기
- **판독 서비스가 혼잡합니다** → Upstage 초당 한도. 자동 재시도 후에도 실패한 경우. 사용량이 늘면 Upstage Tier 상향
- **무료 프로젝트가 잠들었다(paused)** → Supabase 대시보드에서 Restore. 7일 미접속 시 발생. 실서비스는 Pro 플랜
- 실시간 오류는 Edge Functions → `extract-contract` → **Logs** 에서 확인
