-- ============================================================
-- 임대지기 3단계-①: 세무용 데이터 구조
--   앱은 지금처럼 app_state(JSON) 에 저장한다. 이 파일은 그 JSON 을
--   부가세·종소세 자동화에 맞는 정규화 표로 "자동 전개" 하고,
--   직원이 Table Editor 에서 한글 열 이름으로 보는 뷰를 만든다.
--   Supabase SQL Editor 에 전체 붙여넣기 → Run (여러 번 실행해도 안전)
-- 원칙: 값을 덮어쓰지 않고 이력(적용일)으로 남긴다 · 표준 코드로 저장한다 · 근거 자료를 함께 보존한다
-- ============================================================

-- ------------------------------------------------------------
-- 0) 공통
-- ------------------------------------------------------------
create or replace function public.norm_bizno(t text) returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(t,''), '[^0-9]', '', 'g'), '')
$$;
comment on function public.norm_bizno is '사업자등록번호 숫자 10자리만 남김 (표준화)';

create or replace function public.fmt_bizno(t text) returns text language sql immutable as $$
  select case when length(public.norm_bizno(t)) = 10
              then substr(public.norm_bizno(t),1,3)||'-'||substr(public.norm_bizno(t),4,2)||'-'||substr(public.norm_bizno(t),6,5)
              else t end
$$;

create or replace function public.jnum(j jsonb, k text) returns numeric language sql immutable as $$
  select case when jsonb_typeof(j->k) = 'number' then (j->>k)::numeric
              when jsonb_typeof(j->k) = 'string' and (j->>k) ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>k)::numeric
              else null end
$$;
create or replace function public.jdate(j jsonb, k text) returns date language sql immutable as $$
  select case when (j->>k) ~ '^\d{4}-\d{2}-\d{2}' then (j->>k)::date else null end
$$;
create or replace function public.jbool(j jsonb, k text) returns boolean language sql immutable as $$
  select case when jsonb_typeof(j->k) = 'boolean' then (j->k)::boolean
              when (j->>k) in ('true','1') then true
              when (j->>k) in ('false','0') then false
              else null end
$$;

-- ------------------------------------------------------------
-- 1) 사업장 (임대인 1명이 사업자등록을 여러 개 가질 수 있음)
-- ------------------------------------------------------------
create table if not exists public.businesses (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  biz_no        text,                              -- 사업자등록번호 (숫자 10자리)
  biz_name      text,                              -- 상호
  owner_name    text,                              -- 대표자(임대인) 성명
  tax_type      text check (tax_type in ('general','simple','exempt') or tax_type is null), -- 일반/간이/면세
  biz_addr      text,                              -- 사업장 소재지
  biz_start     date,                              -- 개업일
  share_rate    numeric(5,2) default 100,          -- 공동사업자 지분율(%)
  industry_code text,                              -- 국세청 업종코드 (예: 701201 비주거용 건물 임대)
  is_primary    boolean default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists businesses_user_bizno on public.businesses (user_id, coalesce(biz_no,''));
comment on table  public.businesses is '사업장: 임대인의 사업자등록 단위(부가세 신고 단위)';
comment on column public.businesses.biz_no is '사업자등록번호 (하이픈 없는 10자리)';
comment on column public.businesses.tax_type is '과세유형 general=일반과세 simple=간이과세 exempt=면세사업자(주택임대)';
comment on column public.businesses.share_rate is '공동사업자 지분율 % (단독이면 100)';
comment on column public.businesses.industry_code is '국세청 업종코드';

-- ------------------------------------------------------------
-- 2) 물건 (임대 목적물)  — 취득 정보는 종소세 감가상각·양도세 기초자료
-- ------------------------------------------------------------
create table if not exists public.properties (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  business_id     uuid references public.businesses(id) on delete set null,
  app_key         text not null,                   -- 앱 계약 id (현재 1계약=1물건)
  name            text,
  ptype           text,                            -- shop/office/house/land/etc
  addr            text,
  floor           text,                            -- 층
  unit            text,                            -- 호수
  area_m2         numeric(10,2),
  tax_kind        text check (tax_kind in ('taxable','exempt')), -- 과세/면세(주택)
  acq_date        date,                            -- 취득일
  acq_price       numeric(15,0),                   -- 취득가액(총액)
  land_price      numeric(15,0),                   -- 토지가액(안분)
  building_price  numeric(15,0),                   -- 건물가액(안분) → 감가상각 대상
  is_registered_rental_house boolean,              -- 등록임대주택 여부
  deleted_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, app_key)
);
comment on table  public.properties is '임대 물건. 층·호수·면적은 부동산임대공급가액명세서, 취득 정보는 감가상각 기초자료';
comment on column public.properties.tax_kind is 'taxable=과세(상가·사무실·토지 등) exempt=면세(주택임대용역)';

-- ------------------------------------------------------------
-- 3) 임대계약 + 조건 이력
-- ------------------------------------------------------------
create table if not exists public.leases (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  property_id     uuid references public.properties(id) on delete set null,
  app_contract_id text not null,
  tenant_name     text,
  tenant_phone    text,
  tenant_biz_no   text,                            -- 임차인 사업자등록번호 (10자리)
  tenant_biz_name text,
  tenant_kind     text,                            -- business(사업자)/individual(개인)/unknown
  deposit         numeric(15,0) default 0,
  rent            numeric(15,0) default 0,         -- 앱 입력값(월 임대료)
  mgmt_fee        numeric(15,0) default 0,
  vat_separate    boolean,                         -- 부가세 별도 명시 여부
  pay_day         int,
  lease_start     date,
  lease_end       date,
  memo            text,
  auto_registered boolean default false,
  review          jsonb,                           -- AI 점검표 (근거 보존)
  photos          jsonb,                           -- Storage 경로 목록 (근거 보존)
  deleted_at      timestamptz,                     -- 앱에서 삭제되면 표시만 (이력 보존)
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, app_contract_id)
);
comment on table public.leases is '임대차계약 (현재값). 조건 변경 이력은 lease_terms';

create table if not exists public.lease_terms (
  id              bigserial primary key,
  lease_id        uuid not null references public.leases(id) on delete cascade,
  user_id         uuid not null,
  effective_from  date not null,
  effective_to    date,                            -- null = 현재 적용 중
  deposit         numeric(15,0),
  rent            numeric(15,0),
  mgmt_fee        numeric(15,0),
  vat_separate    boolean,
  recorded_at     timestamptz not null default now()
);
create index if not exists lease_terms_lease on public.lease_terms (lease_id, effective_from);
comment on table public.lease_terms is '임대조건 이력: 보증금·월세·관리비가 바뀐 시점을 적용일로 보존 (간주임대료·공급가액 산정 근거)';

-- ------------------------------------------------------------
-- 4) 임대료 원장 (월 단위 청구·입금)
-- ------------------------------------------------------------
create table if not exists public.rent_ledger (
  id            bigserial primary key,
  user_id       uuid not null,
  lease_id      uuid not null references public.leases(id) on delete cascade,
  year_month    text not null,                     -- 'YYYY-MM'
  due_date      date,                              -- 납부 약정일 = 공급시기(대가의 각 부분을 받기로 한 날)
  supply_amount numeric(15,0),                     -- 공급가액
  vat_amount    numeric(15,0),                     -- 세액 (면세·부가세 없음이면 0)
  mgmt_amount   numeric(15,0),
  paid_at       date,
  paid_amount   numeric(15,0),
  status        text,                              -- paid/unpaid/partial/pending
  source        text default 'app',                -- app / bank(통장 매칭) / manual
  updated_at    timestamptz not null default now(),
  unique (lease_id, year_month)
);
comment on table public.rent_ledger is '월별 임대료 원장. 부가세 매출(공급가액·세액)과 종소세 수입금액의 원천';
comment on column public.rent_ledger.due_date is '납부 약정일. 임대용역의 공급시기 판단 기준(원문 확인: 부가가치세법 시행령 공급시기 규정)';

-- ------------------------------------------------------------
-- 5) 세금계산서 (초안 → 발급 → 전송)
-- ------------------------------------------------------------
create table if not exists public.tax_invoices (
  id             bigserial primary key,
  user_id        uuid not null,
  lease_id       uuid not null references public.leases(id) on delete cascade,
  business_id    uuid references public.businesses(id) on delete set null,
  year_month     text not null,
  issue_date     date,                             -- 작성일자 (= 공급시기)
  deadline       date,                             -- 발급기한: 공급시기 다음 달 10일
  supplier_bizno text,
  buyer_bizno    text,
  buyer_name     text,
  item           text,
  supply_amount  numeric(15,0),
  vat_amount     numeric(15,0),
  basis          text,                             -- 계산 근거: separate(별도) / included(포함→÷1.1) / exempt
  status         text default 'draft',             -- draft / ready / issued / sent / cancelled / blocked
  block_reason   text,                             -- 예: 임차인 사업자번호 없음
  approval_no    text,                             -- 국세청 승인번호
  issued_at      timestamptz,
  provider       text,                             -- 발급대행사 코드 (추후)
  provider_ref   text,
  updated_at     timestamptz not null default now(),
  unique (lease_id, year_month)
);
comment on table public.tax_invoices is '월별 세금계산서. 앱의 초안·발급 상태를 반영하고, 발급대행 API 연결 시 승인번호가 채워짐';
comment on column public.tax_invoices.basis is 'separate=월세를 공급가액으로 보고 10% 가산 / included=월세에 부가세 포함(÷1.1) / exempt=면세';

-- ------------------------------------------------------------
-- 6) 필요경비 (종소세) — 앱 입력 화면은 후속. 표는 먼저 준비
-- ------------------------------------------------------------
create table if not exists public.expenses (
  id            bigserial primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  business_id   uuid references public.businesses(id) on delete set null,
  property_id   uuid references public.properties(id) on delete set null,
  expense_date  date not null,
  category      text not null,   -- property_tax(재산세) loan_interest(대출이자) repair(수선비) insurance(보험료) brokerage(중개수수료) mgmt(관리비지출) depreciation(감가상각) other
  amount        numeric(15,0) not null,
  vat_amount    numeric(15,0) default 0,
  vendor        text,
  vendor_bizno  text,
  evidence      text,            -- 증빙 종류: tax_invoice/card/cash_receipt/receipt/none
  evidence_path text,            -- Storage 경로
  memo          text,
  created_at    timestamptz not null default now()
);
comment on table public.expenses is '필요경비 원장 (종소세). 증빙 사진은 Storage 경로로 보존';

-- ------------------------------------------------------------
-- 7) 간주임대료 이자율 (국세청 고시) — 값은 원문 확인 후 입력
-- ------------------------------------------------------------
create table if not exists public.deemed_rent_rates (
  tax_year  int primary key,
  rate      numeric(6,4) not null,                 -- 예: 0.0350 = 연 3.5%
  source    text,                                  -- 근거(부가가치세법 시행규칙 조문·고시 번호)
  note      text
);
comment on table public.deemed_rent_rates is '보증금 간주임대료 정기예금이자율(연도별). 국세법령정보시스템 원문 확인 후 입력';

-- ------------------------------------------------------------
-- 8) 신고기간 · 산출 결과 · 검토 상태 (앱이 만들고 세무사가 검토·확정)
-- ------------------------------------------------------------
create table if not exists public.filing_periods (
  id            bigserial primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  business_id   uuid references public.businesses(id) on delete set null,
  filing_type   text not null,                     -- vat_1(1기확정) vat_2(2기확정) vat_pre(예정) income(종소세) house_status(사업장현황신고)
  period_label  text,
  period_start  date,
  period_end    date,
  due_date      date,
  status        text default 'collecting',         -- collecting(수집중) ready(자료완결) review(세무사검토) filed(신고완료)
  computed      jsonb,                             -- 산출값(공급가액·간주임대료·세액 등) 스냅샷
  completeness  jsonb,                             -- 완결성 점검 결과
  reviewed_by   uuid,
  reviewed_at   timestamptz,
  filed_at      timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.filing_periods is '신고 단위. 앱이 자료를 모아 산출 → 담당 세무사가 검토·확정(세무사법상 대리 업무는 세무사가 수행)';

-- ------------------------------------------------------------
-- 9) 동의 이력 · 구독
-- ------------------------------------------------------------
create table if not exists public.consents (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null,      -- terms / privacy / tenant_data_share(임차인정보 제공) / tax_agent(세무대리 수임) / marketing
  version     text,
  granted_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  meta        jsonb
);
comment on table public.consents is '약관·개인정보·임차인정보 제공·세무대리 수임 동의 이력 (철회 포함)';

create table if not exists public.subscriptions (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  plan          text not null default 'trial',     -- trial / basic / pro
  price_monthly numeric(10,0),
  status        text not null default 'active',    -- active / past_due / cancelled
  started_at    date default current_date,
  ends_at       date,
  meta          jsonb,
  updated_at    timestamptz not null default now()
);
comment on table public.subscriptions is '월 구독 상태';

-- updated_at 갱신
do $$ declare t text; begin
  foreach t in array array['businesses','properties','leases','rent_ledger','tax_invoices','filing_periods','subscriptions'] loop
    execute format('drop trigger if exists trg_%s_touch on public.%I', t, t);
    execute format('create trigger trg_%s_touch before update on public.%I for each row execute function public.touch_updated_at()', t, t);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 10) 행 단위 보안: 본인 전체 / 직원 읽기 (deemed_rent_rates 는 모두 읽기)
-- ------------------------------------------------------------
do $$ declare t text; begin
  foreach t in array array['businesses','properties','leases','lease_terms','rent_ledger','tax_invoices','expenses','filing_periods','consents','subscriptions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "%s: own" on public.%I', t, t);
    execute format('create policy "%s: own" on public.%I for all using (auth.uid() = user_id) with check (auth.uid() = user_id)', t, t);
    execute format('drop policy if exists "%s: staff" on public.%I', t, t);
    execute format('create policy "%s: staff" on public.%I for all using (public.is_staff()) with check (public.is_staff())', t, t);
  end loop;
end $$;
alter table public.deemed_rent_rates enable row level security;
drop policy if exists "rates: read" on public.deemed_rent_rates;
create policy "rates: read" on public.deemed_rent_rates for select using (true);
drop policy if exists "rates: staff write" on public.deemed_rent_rates;
create policy "rates: staff write" on public.deemed_rent_rates for all using (public.is_staff()) with check (public.is_staff());

-- ------------------------------------------------------------
-- 11) app_state(JSON) → 세무용 표 자동 전개
-- ------------------------------------------------------------
create or replace function public.expand_app_state(p_user uuid, d jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  L      jsonb := coalesce(d->'landlord', '{}'::jsonb);
  c      jsonb;
  v_biz_id uuid;
  v_prop_id uuid;
  v_lease_id uuid;
  ids    text[] := '{}';
  v_tax_kind text;
  v_start date; v_end date; v_ym date; v_last date;
  v_due date; v_supply numeric; v_vat numeric; v_basis text;
  r      jsonb; inv jsonb; k text;
  cur    record;
begin
  -- 예시 데이터는 전개하지 않음
  if coalesce(d->>'demo','false') = 'true' then return; end if;

  -- 사업장 (임대인 정보 1건 = 기본 사업장)
  insert into public.businesses (user_id, biz_no, biz_name, owner_name, tax_type, biz_addr, share_rate, biz_start, is_primary)
  values (p_user, public.norm_bizno(L->>'bizNo'), nullif(L->>'bizName',''), nullif(L->>'name',''),
          case L->>'taxType' when 'general' then 'general' when 'simple' then 'simple' when 'exempt' then 'exempt' else null end,
          nullif(L->>'addr',''), coalesce(public.jnum(L,'shareRate'),100), public.jdate(L,'bizStart'), true)
  on conflict (user_id, coalesce(biz_no,'')) do update
    set biz_name = excluded.biz_name, owner_name = excluded.owner_name, tax_type = excluded.tax_type,
        biz_addr = excluded.biz_addr, share_rate = excluded.share_rate, biz_start = excluded.biz_start
  returning id into v_biz_id;

  -- 계약 → 물건 + 임대계약 + 조건이력 + 원장 + 세금계산서
  for c in select * from jsonb_array_elements(coalesce(d->'contracts','[]'::jsonb)) loop
    ids := ids || (c->>'id');
    v_tax_kind := case when c->>'taxKind' in ('taxable','exempt') then c->>'taxKind'
                       when c->>'type' = 'house' then 'exempt' else 'taxable' end;

    insert into public.properties (user_id, business_id, app_key, name, ptype, addr, floor, unit, area_m2, tax_kind,
                                   acq_date, acq_price, land_price, building_price, is_registered_rental_house, deleted_at)
    values (p_user, v_biz_id, c->>'id', c->>'name', c->>'type', c->>'addr', nullif(c->>'floor',''), nullif(c->>'unit',''),
            public.jnum(c,'area'), v_tax_kind, public.jdate(c,'acqDate'), public.jnum(c,'acqPrice'), public.jnum(c,'landPrice'),
            case when public.jnum(c,'acqPrice') is not null and public.jnum(c,'landPrice') is not null
                 then public.jnum(c,'acqPrice') - public.jnum(c,'landPrice') else public.jnum(c,'buildingPrice') end,
            public.jbool(c,'registeredRental'), null)
    on conflict (user_id, app_key) do update
      set business_id = excluded.business_id, name = excluded.name, ptype = excluded.ptype, addr = excluded.addr,
          floor = excluded.floor, unit = excluded.unit, area_m2 = excluded.area_m2, tax_kind = excluded.tax_kind,
          acq_date = excluded.acq_date, acq_price = excluded.acq_price, land_price = excluded.land_price,
          building_price = excluded.building_price, is_registered_rental_house = excluded.is_registered_rental_house, deleted_at = null
    returning id into v_prop_id;

    insert into public.leases (user_id, property_id, app_contract_id, tenant_name, tenant_phone, tenant_biz_no, tenant_biz_name, tenant_kind,
                               deposit, rent, mgmt_fee, vat_separate, pay_day, lease_start, lease_end, memo, auto_registered, review, photos, deleted_at)
    values (p_user, v_prop_id, c->>'id', c->>'tenant', c->>'tenantPhone', public.norm_bizno(c->>'tenantBiz'), nullif(c->>'tenantBizName',''),
            case when public.norm_bizno(c->>'tenantBiz') is not null then 'business' when coalesce(c->>'tenant','') <> '' then 'individual' else 'unknown' end,
            coalesce(public.jnum(c,'deposit'),0), coalesce(public.jnum(c,'rent'),0), coalesce(public.jnum(c,'mgmt'),0), public.jbool(c,'vatSeparate'),
            public.jnum(c,'payDay')::int, public.jdate(c,'start'), public.jdate(c,'end'), c->>'memo', coalesce(public.jbool(c,'autoRegistered'),false),
            c->'review', c->'photos', null)
    on conflict (user_id, app_contract_id) do update
      set property_id = excluded.property_id, tenant_name = excluded.tenant_name, tenant_phone = excluded.tenant_phone,
          tenant_biz_no = excluded.tenant_biz_no, tenant_biz_name = excluded.tenant_biz_name, tenant_kind = excluded.tenant_kind,
          deposit = excluded.deposit, rent = excluded.rent, mgmt_fee = excluded.mgmt_fee, vat_separate = excluded.vat_separate,
          pay_day = excluded.pay_day, lease_start = excluded.lease_start, lease_end = excluded.lease_end, memo = excluded.memo,
          auto_registered = excluded.auto_registered, review = coalesce(excluded.review, public.leases.review),
          photos = excluded.photos, deleted_at = null
    returning id, lease_start, lease_end into v_lease_id, v_start, v_end;

    -- 조건 이력: 현재 적용 중인 조건과 다르면 이전 조건을 닫고 새 조건을 연다
    select * into cur from public.lease_terms t where t.lease_id = v_lease_id and t.effective_to is null order by effective_from desc limit 1;
    if cur is null then
      insert into public.lease_terms (lease_id, user_id, effective_from, deposit, rent, mgmt_fee, vat_separate)
      values (v_lease_id, p_user, coalesce(v_start, current_date), coalesce(public.jnum(c,'deposit'),0), coalesce(public.jnum(c,'rent'),0), coalesce(public.jnum(c,'mgmt'),0), public.jbool(c,'vatSeparate'));
    elsif cur.deposit is distinct from coalesce(public.jnum(c,'deposit'),0) or cur.rent is distinct from coalesce(public.jnum(c,'rent'),0)
       or cur.mgmt_fee is distinct from coalesce(public.jnum(c,'mgmt'),0) or cur.vat_separate is distinct from public.jbool(c,'vatSeparate') then
      if cur.effective_from >= current_date then
        -- 같은 날 여러 번 고친 경우: 그 행을 갱신
        update public.lease_terms set deposit = coalesce(public.jnum(c,'deposit'),0), rent = coalesce(public.jnum(c,'rent'),0), mgmt_fee = coalesce(public.jnum(c,'mgmt'),0), vat_separate = public.jbool(c,'vatSeparate'), recorded_at = now() where id = cur.id;
      else
        update public.lease_terms set effective_to = current_date - 1 where id = cur.id;
        insert into public.lease_terms (lease_id, user_id, effective_from, deposit, rent, mgmt_fee, vat_separate)
        values (v_lease_id, p_user, current_date, coalesce(public.jnum(c,'deposit'),0), coalesce(public.jnum(c,'rent'),0), coalesce(public.jnum(c,'mgmt'),0), public.jbool(c,'vatSeparate'));
      end if;
    end if;

    -- 월별 원장·세금계산서: 계약 시작월 ~ min(종료월, 이번 달)
    if v_start is not null then
      v_last := least(coalesce(v_end, current_date), current_date);
      v_ym := date_trunc('month', v_start)::date;
      while v_ym <= v_last loop
        k := to_char(v_ym, 'YYYY-MM');
        v_due := (v_ym + (least(coalesce(public.jnum(c,'payDay')::int,1), extract(day from (v_ym + interval '1 month - 1 day'))::int) - 1))::date;
        -- 그 달에 적용되는 조건(이력)으로 공급가액 산정
        select * into cur from public.lease_terms t where t.lease_id = v_lease_id and t.effective_from <= v_due and (t.effective_to is null or t.effective_to >= v_due) order by effective_from desc limit 1;
        if cur is null then select * into cur from public.lease_terms t where t.lease_id = v_lease_id order by effective_from limit 1; end if;
        if v_tax_kind = 'exempt' then
          v_supply := coalesce(cur.rent,0); v_vat := 0; v_basis := 'exempt';
        elsif coalesce(cur.vat_separate,true) then
          v_supply := coalesce(cur.rent,0); v_vat := round(coalesce(cur.rent,0) * 0.1); v_basis := 'separate';
        else
          v_supply := round(coalesce(cur.rent,0) * 10 / 11); v_vat := coalesce(cur.rent,0) - v_supply; v_basis := 'included';
        end if;

        r := d->'rents'->(c->>'id' || '_' || k);
        insert into public.rent_ledger (user_id, lease_id, year_month, due_date, supply_amount, vat_amount, mgmt_amount, paid_at, paid_amount, status)
        values (p_user, v_lease_id, k, v_due, v_supply, v_vat, coalesce(cur.mgmt_fee,0), public.jdate(coalesce(r,'{}'::jsonb),'paidAt'), public.jnum(coalesce(r,'{}'::jsonb),'amount'),
                case when r is not null and coalesce(r->>'status','paid') = 'paid' then 'paid'
                     when r is not null then r->>'status'
                     when v_due < current_date then 'unpaid' else 'pending' end)
        on conflict (lease_id, year_month) do update
          set due_date = excluded.due_date, supply_amount = excluded.supply_amount, vat_amount = excluded.vat_amount, mgmt_amount = excluded.mgmt_amount,
              paid_at = coalesce(excluded.paid_at, public.rent_ledger.paid_at), paid_amount = coalesce(excluded.paid_amount, public.rent_ledger.paid_amount),
              status = case when public.rent_ledger.source = 'bank' then public.rent_ledger.status else excluded.status end;

        if v_tax_kind = 'taxable' then
          inv := d->'invoices'->(c->>'id' || '_' || k);
          insert into public.tax_invoices (user_id, lease_id, business_id, year_month, issue_date, deadline, supplier_bizno, buyer_bizno, buyer_name, item,
                                           supply_amount, vat_amount, basis, status, block_reason, approval_no, issued_at)
          values (p_user, v_lease_id, v_biz_id, k, v_due, (date_trunc('month', v_due) + interval '1 month' + interval '9 days')::date,
                  public.norm_bizno(L->>'bizNo'), public.norm_bizno(c->>'tenantBiz'), coalesce(nullif(c->>'tenantBizName',''), c->>'tenant'),
                  coalesce(c->>'name','') || ' ' || k || ' 임대료', v_supply, v_vat, v_basis,
                  case when coalesce(public.jbool(coalesce(inv,'{}'::jsonb),'issued'),false) then 'issued'
                       when public.norm_bizno(c->>'tenantBiz') is null then 'blocked' else 'draft' end,
                  case when public.norm_bizno(c->>'tenantBiz') is null then '임차인 사업자등록번호 없음' else null end,
                  nullif(inv->>'no',''), case when (inv->>'issuedAt') ~ '^\d{4}-\d{2}-\d{2}' then (inv->>'issuedAt')::date::timestamptz else null end)
          on conflict (lease_id, year_month) do update
            set issue_date = excluded.issue_date, deadline = excluded.deadline, supplier_bizno = excluded.supplier_bizno, buyer_bizno = excluded.buyer_bizno,
                buyer_name = excluded.buyer_name, item = excluded.item, supply_amount = excluded.supply_amount, vat_amount = excluded.vat_amount, basis = excluded.basis,
                -- 발급대행으로 실제 발급된 행(issued/sent + provider)은 앱 값으로 되돌리지 않음
                status = case when public.tax_invoices.provider is not null then public.tax_invoices.status else excluded.status end,
                block_reason = excluded.block_reason,
                approval_no = coalesce(public.tax_invoices.approval_no, excluded.approval_no),
                issued_at = coalesce(public.tax_invoices.issued_at, excluded.issued_at);
        end if;
        v_ym := (v_ym + interval '1 month')::date;
      end loop;
    end if;
  end loop;

  -- 앱에서 사라진 계약은 삭제 표시만 (이력 보존)
  update public.leases set deleted_at = now() where user_id = p_user and deleted_at is null and not (app_contract_id = any(ids));
  update public.properties set deleted_at = now() where user_id = p_user and deleted_at is null and not (app_key = any(ids));
end $$;
comment on function public.expand_app_state is 'app_state.data(JSON) 를 사업장·물건·계약·조건이력·원장·세금계산서 표로 전개 (예시 데이터 제외)';

create or replace function public.trg_expand_app_state() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.expand_app_state(new.user_id, new.data);
  return new;
exception when others then
  -- 전개 실패가 앱 저장을 막지 않도록: 기록만 남김
  insert into public.extract_logs (user_id, engine, ok, error) values (new.user_id, 'expand_app_state', false, left(sqlerrm, 500));
  return new;
end $$;
drop trigger if exists trg_app_state_expand on public.app_state;
create trigger trg_app_state_expand after insert or update of data on public.app_state for each row execute function public.trg_expand_app_state();

-- 기존 저장분 일괄 전개
do $$ declare s record; begin
  for s in select user_id, data from public.app_state loop perform public.expand_app_state(s.user_id, s.data); end loop;
end $$;

-- ------------------------------------------------------------
-- 12) 기존 뷰 정정 (앱 실제 키: rents.status/paidAt/amount, invoices.issued/no/issuedAt)
-- ------------------------------------------------------------
drop view if exists public.v_rent_payments;
create view public.v_rent_payments as
select s.user_id, split_part(k.key,'_',1) as contract_id, split_part(k.key,'_',2) as year_month,
       k.value->>'status' as status, k.value->>'paidAt' as paid_at, (k.value->>'amount')::numeric as amount
from public.app_state s, jsonb_each(coalesce(s.data->'rents','{}'::jsonb)) k;
drop view if exists public.v_invoices;
create view public.v_invoices as
select s.user_id, split_part(k.key,'_',1) as contract_id, split_part(k.key,'_',2) as year_month,
       (k.value->>'issued')::boolean as issued, k.value->>'no' as approval_no, k.value->>'issuedAt' as issued_at
from public.app_state s, jsonb_each(coalesce(s.data->'invoices','{}'::jsonb)) k;
alter view public.v_rent_payments set (security_invoker = on);
alter view public.v_invoices set (security_invoker = on);

-- ------------------------------------------------------------
-- 13) 직원용 한글 뷰 (Table Editor 에서 바로 보기 / 엑셀 내려받기 머리글이 한글)
-- ------------------------------------------------------------
create or replace view public."임대인현황" as
select p.id                                   as "계정ID",
       coalesce(b.owner_name, p.name)         as "임대인",
       p.email                                as "이메일",
       p.phone                                as "휴대폰",
       public.fmt_bizno(b.biz_no)             as "사업자등록번호",
       b.biz_name                             as "상호",
       case b.tax_type when 'general' then '일반과세' when 'simple' then '간이과세' when 'exempt' then '면세' end as "과세유형",
       b.share_rate                           as "지분율(%)",
       (select count(*) from public.leases l where l.user_id = p.id and l.deleted_at is null) as "계약수",
       (select count(*) from public.tax_invoices t where t.user_id = p.id and t.status in ('draft','blocked') and t.deadline < current_date) as "기한경과 미발급",
       sub.plan                               as "구독",
       s.updated_at                           as "마지막 동기화"
from public.profiles p
left join public.businesses b on b.user_id = p.id and b.is_primary
left join public.app_state s on s.user_id = p.id
left join public.subscriptions sub on sub.user_id = p.id;

create or replace view public."임대현황" as
select l.user_id                              as "계정ID",
       coalesce(b.owner_name,'')              as "임대인",
       public.fmt_bizno(b.biz_no)             as "임대인 사업자번호",
       pr.name                                as "물건명",
       case pr.ptype when 'shop' then '상가' when 'office' then '사무실' when 'house' then '주택' when 'land' then '토지' else '기타' end as "유형",
       case pr.tax_kind when 'taxable' then '과세' else '면세' end as "과세구분",
       pr.addr                                as "소재지",
       pr.floor                               as "층",
       pr.unit                                as "호수",
       pr.area_m2                             as "면적(㎡)",
       l.tenant_name                          as "임차인",
       l.tenant_biz_name                      as "임차인 상호",
       public.fmt_bizno(l.tenant_biz_no)      as "임차인 사업자번호",
       l.deposit                              as "보증금",
       l.rent                                 as "월임대료",
       l.mgmt_fee                             as "관리비",
       case l.vat_separate when true then '별도' when false then '포함' else '미표기' end as "부가세",
       l.pay_day                              as "납부일",
       l.lease_start                          as "임대시작일",
       l.lease_end                            as "임대종료일",
       case when l.deleted_at is not null then '삭제' when l.lease_end < current_date then '만료' else '진행' end as "상태",
       l.auto_registered                      as "AI자동등록",
       l.updated_at                           as "갱신"
from public.leases l
left join public.properties pr on pr.id = l.property_id
left join public.businesses b on b.id = pr.business_id;

create or replace view public."임대조건이력" as
select t.user_id as "계정ID", pr.name as "물건명", l.tenant_name as "임차인",
       t.effective_from as "적용시작", t.effective_to as "적용종료",
       t.deposit as "보증금", t.rent as "월임대료", t.mgmt_fee as "관리비",
       case t.vat_separate when true then '별도' when false then '포함' else '미표기' end as "부가세", t.recorded_at as "기록시각"
from public.lease_terms t join public.leases l on l.id = t.lease_id left join public.properties pr on pr.id = l.property_id;

create or replace view public."임대료원장" as
select r.user_id as "계정ID", pr.name as "물건명", l.tenant_name as "임차인",
       r.year_month as "귀속월", r.due_date as "납부약정일",
       r.supply_amount as "공급가액", r.vat_amount as "세액", r.mgmt_amount as "관리비",
       r.paid_at as "입금일", r.paid_amount as "입금액",
       case r.status when 'paid' then '입금' when 'unpaid' then '미납' when 'partial' then '일부입금' when 'pending' then '예정' else r.status end as "상태",
       case r.source when 'app' then '앱' when 'bank' then '통장매칭' else r.source end as "출처"
from public.rent_ledger r join public.leases l on l.id = r.lease_id left join public.properties pr on pr.id = l.property_id;

create or replace view public."세금계산서" as
select t.user_id as "계정ID", public.fmt_bizno(t.supplier_bizno) as "공급자 사업자번호", pr.name as "물건명",
       t.year_month as "귀속월", t.issue_date as "작성일자", t.deadline as "발급기한",
       t.buyer_name as "공급받는자", public.fmt_bizno(t.buyer_bizno) as "공급받는자 사업자번호",
       t.item as "품목", t.supply_amount as "공급가액", t.vat_amount as "세액", t.supply_amount + t.vat_amount as "합계",
       case t.basis when 'separate' then '부가세 별도' when 'included' then '부가세 포함(÷1.1)' else '면세' end as "산정근거",
       case t.status when 'draft' then '초안' when 'ready' then '발급대기' when 'issued' then '발급완료' when 'sent' then '전송완료' when 'cancelled' then '취소' when 'blocked' then '발급불가' else t.status end as "상태",
       t.block_reason as "불가사유", t.approval_no as "승인번호", t.issued_at as "발급시각"
from public.tax_invoices t join public.leases l on l.id = t.lease_id left join public.properties pr on pr.id = l.property_id;

create or replace view public."신고기간" as
select f.user_id as "계정ID", b.owner_name as "임대인", public.fmt_bizno(b.biz_no) as "사업자번호",
       case f.filing_type when 'vat_1' then '부가세 1기 확정' when 'vat_2' then '부가세 2기 확정' when 'vat_pre' then '부가세 예정' when 'income' then '종합소득세' when 'house_status' then '사업장현황신고' else f.filing_type end as "신고종류",
       f.period_label as "기간", f.period_start as "시작", f.period_end as "종료", f.due_date as "신고기한",
       case f.status when 'collecting' then '수집중' when 'ready' then '자료완결' when 'review' then '세무사검토' when 'filed' then '신고완료' else f.status end as "상태",
       f.computed as "산출값", f.completeness as "완결성", f.reviewed_at as "검토시각", f.filed_at as "신고시각"
from public.filing_periods f left join public.businesses b on b.id = f.business_id;

-- 부가세 신고용: 부동산임대공급가액명세서 초안 (기간은 조회 시 필터)
create or replace view public."임대공급가액명세" as
select r.user_id as "계정ID", public.fmt_bizno(b.biz_no) as "사업자번호", r.year_month as "귀속월",
       pr.addr as "소재지", pr.floor as "층", pr.unit as "호수", pr.area_m2 as "면적(㎡)",
       l.tenant_biz_name as "임차인 상호", public.fmt_bizno(l.tenant_biz_no) as "임차인 사업자번호",
       l.lease_start as "입주일", l.lease_end as "퇴거일",
       t.deposit as "보증금", t.rent as "월임대료", r.supply_amount as "공급가액(임대료)", r.vat_amount as "세액"
from public.rent_ledger r
join public.leases l on l.id = r.lease_id
left join public.properties pr on pr.id = l.property_id
left join public.businesses b on b.id = pr.business_id
left join lateral (select * from public.lease_terms x where x.lease_id = l.id and x.effective_from <= r.due_date and (x.effective_to is null or x.effective_to >= r.due_date) order by x.effective_from desc limit 1) t on true
where pr.tax_kind = 'taxable';

do $$ declare v text; begin
  foreach v in array array['임대인현황','임대현황','임대조건이력','임대료원장','세금계산서','신고기간','임대공급가액명세'] loop
    execute format('alter view public.%I set (security_invoker = on)', v);
  end loop;
end $$;

select 'rentkeeper tax schema ready' as status;
