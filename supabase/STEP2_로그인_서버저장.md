# 2단계 설치 안내 — 로그인 + 회사 서버 저장

임대인이 로그인하면 임대현황·수납·세금계산서·계약서 사진이 **회사 Supabase(서울)** 에 임대인별로 저장됩니다.
폰을 바꿔도 이어서 쓸 수 있고, 회사는 Table Editor 에서 전 고객 현황을 표로 봅니다. 판독 서버는 로그인한 사용자만 호출할 수 있게 잠깁니다.

운영자가 한 번만 합니다(약 10분). 임대인은 이메일·비밀번호로 가입/로그인만 하면 됩니다. 카카오 로그인은 파일럿 전에 켭니다(아래 부록).

---

## A. 데이터베이스 만들기 (3분)

1. Supabase 대시보드 → `rentkeeper` 프로젝트 → 왼쪽 메뉴 **SQL Editor** (아이콘 `>_`)
2. **New query** → 저장소의 `supabase/migrations/001_init.sql` 파일을 메모장으로 열어 전체 복사 → 붙여넣기 → **Run** (Ctrl+Enter)
3. 아래 결과에 `rentkeeper schema ready` 가 보이면 완료. (여러 번 실행해도 안전합니다)
4. 확인: 왼쪽 **Table Editor** 에 `profiles`, `app_state`, `staff`, `extract_logs` 표가 생겼는지. **Storage** 에 `contract-photos` 버킷이 생겼는지.

## B. 로그인 방식 켜기 (2분)

1. 왼쪽 메뉴 **Authentication** → **Sign In / Providers** (또는 Providers)
2. **Email** 이 켜져 있는지 확인(기본 ON).
3. 데모 편의를 위해 **Confirm email** 스위치를 **끄기(OFF)** → Save.
   - 켜 두면 가입 시 확인 메일의 링크를 눌러야 로그인됩니다. 실서비스에서는 켜는 것을 권장(그때 메일 발송 설정 필요).
4. **Authentication → URL Configuration**:
   - Site URL: `https://jssong-hub.github.io/workpace/rentkeeper/`
   - Redirect URLs 에 추가: `https://jssong-hub.github.io/workpace/rentkeeper/**`

## C. 앱에 공개 키 넣기 (2분)

1. 왼쪽 맨 아래 **⚙ Project Settings → API Keys**
2. **Publishable key** (`sb_publishable_…`) 또는 Legacy 탭의 **anon public** 키를 복사. (⚠ `service_role` / secret 키는 절대 앱에 넣지 않습니다)
3. `rentkeeper/index.html` 과 `임대지기/index.html` 에서 아래 줄에 붙여 넣고 커밋·푸시
   ```js
   const SUPABASE_ANON_KEY = '';   // → 'sb_publishable_xxxx' 또는 'eyJhbGciOi...'
   ```
   (Claude 에게 키를 알려주면 대신 넣어 커밋합니다. 공개 키이므로 앱 코드에 들어가는 것이 정상입니다.)

## D. 판독 서버 재배포 (2분)

1. **Edge Functions → extract-contract → Code** → 전체 지우고 `supabase/functions/extract-contract/index.ts` 새 내용 붙여넣기 → **Deploy**
2. Settings 의 "Verify JWT with legacy secret" 은 **OFF 그대로** 둡니다 (함수 안에서 직접 로그인 토큰을 검증하므로 새 키 체계에서도 동작).
3. 이제 로그인 없이 호출하면 `401 로그인이 필요합니다` 가 납니다. 개발 중 잠시 풀려면 Secrets 에 `REQUIRE_AUTH` = `false`.

## E. 회사 직원 계정 등록 (선택, 1분)

직원이 전 고객 데이터를 보려면 직원 계정을 `staff` 표에 넣습니다.
1. 직원이 앱에서 이메일로 가입 → **Authentication → Users** 에서 그 계정의 **UID** 복사
2. **SQL Editor** 에서 실행:
   ```sql
   insert into public.staff (user_id, name, role) values ('<UID>', '홍직원', 'admin');
   ```
3. 이후 그 직원은 Table Editor 의 `v_landlords`, `v_contracts`, `v_rent_payments`, `v_invoices` 뷰에서 전체를 조회할 수 있습니다. (대시보드 로그인 자체는 Supabase 계정 권한을 따릅니다)

---

## 동작 확인

1. GitHub Desktop **Push origin** → 폰에서 앱 새로고침 → 로그인 화면이 뜨는지
2. **회원가입** → 바로 로그인되는지(Confirm email OFF 기준)
3. 계약서 촬영 → 판독 → 등록 → 잠시 후 Supabase **Table Editor → app_state** 에 행이 생기고, **Storage → contract-photos** 에 사진이 올라가는지
4. 다른 폰(또는 PC 브라우저)에서 같은 계정으로 로그인 → 같은 계약이 보이는지
5. 설정 → 데이터·동기화 에 계정과 "마지막 저장" 시각이 보이는지

## 문제 해결

- **로그인 화면이 안 뜨고 예전처럼 동작** → `SUPABASE_ANON_KEY` 가 비어 있음(C단계) 또는 푸시 전
- **가입했는데 "확인 메일" 안내만 나옴** → B-3 Confirm email 이 켜져 있음
- **판독 시 "로그인이 필요합니다"** → 로그아웃 후 재로그인. 계속되면 D단계 재배포 확인
- **"서버와 동기화하지 못했습니다"** → A단계 SQL 실행 여부, RLS 정책 확인. 폰에는 저장되며 다음 저장 때 재시도
- **사진이 안 보임(빈 칸)** → Storage 버킷 `contract-photos` 와 정책 확인(A단계 SQL 포함)
- **Invalid API key** → C단계 키를 잘못 복사(service_role 사용 금지, 앞뒤 공백 제거)

---

## 부록. 카카오 로그인 켜기 (파일럿 전)

1. https://developers.kakao.com → 내 애플리케이션 → **애플리케이션 추가** (이름 임대지기, 회사명 대한세무법인)
2. **앱 키** 에서 **REST API 키** 복사. **카카오 로그인 → 활성화 ON**, **보안 → Client Secret 생성** 후 복사, 상태 "사용함"
3. **카카오 로그인 → Redirect URI** 에 추가: `https://lezpolceeqhdsgekidzi.supabase.co/auth/v1/callback`
4. **동의항목**: 닉네임(필수), **카카오계정(이메일)** — 개인 개발자 앱은 "선택 동의"만 가능하고 필수 동의는 비즈 앱 전환 후 가능. Supabase 는 이메일이 필요하므로 **비즈 앱 전환(사업자등록번호 등록) 후 이메일 필수 동의** 를 권장
5. Supabase **Authentication → Providers → Kakao** ON → Client ID = REST API 키, Client Secret = 2번 값 → Save
6. `index.html` 의 `AUTH_PROVIDERS = { email: true, kakao: true }` 로 바꾸고 푸시 → 로그인 화면에 "카카오로 시작하기" 버튼이 나타남

## 데이터 구조 요약

| 표/뷰 | 내용 | 누가 보나 |
|---|---|---|
| `profiles` | 임대인 계정 프로필(이름·연락처·이메일·로그인 방식) | 본인, 직원 |
| `app_state` | 임대인 1명 = 1행. 앱 전체 데이터(JSON). 사진은 경로만 | 본인, 직원(읽기) |
| `staff` | 직원 계정 목록 | 직원 |
| `extract_logs` | 판독 호출 기록(엔진·장수·성공·소요시간) — 사진 없음 | 본인, 직원 |
| `v_landlords` / `v_contracts` / `v_rent_payments` / `v_invoices` | JSON을 표로 펼친 회사용 뷰 | RLS 따름 |
| Storage `contract-photos` | `<user_id>/<contract_id>/…jpg`, 비공개, 1시간 서명 URL로 열람 | 본인, 직원 |
