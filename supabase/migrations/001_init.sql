-- ============================================================
-- 임대지기 2단계: 로그인 + 회사 서버 저장
-- Supabase SQL Editor 에 전체 붙여넣기 → Run (여러 번 실행해도 안전)
-- ============================================================

-- 1) 임대인 프로필 (로그인 계정 1 : 1)
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text,
  phone       text,
  email       text,
  provider    text,                       -- kakao / email ...
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 2) 앱 상태 저장 (임대인 1명 = 1행, 앱 전체 데이터를 JSON으로 보관)
--    임대현황·수납·세금계산서·알림·설정이 모두 들어감. 사진은 Storage에 저장하고 경로만 보관.
create table if not exists public.app_state (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  data        jsonb not null default '{}'::jsonb,
  version     integer not null default 1,
  updated_at  timestamptz not null default now(),
  device      text
);

-- 3) 회사 직원 (전체 열람 권한). 대시보드에서 직원 계정의 uuid를 넣어 관리
create table if not exists public.staff (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  role        text not null default 'staff',     -- staff / admin
  name        text,
  created_at  timestamptz not null default now()
);

-- 4) 판독 호출 기록 (사용량·비용 관리용; 사진은 저장하지 않음)
create table if not exists public.extract_logs (
  id          bigserial primary key,
  user_id     uuid references auth.users(id) on delete set null,
  engine      text,
  pages       integer,
  ok          boolean,
  error       text,
  ms          integer,
  created_at  timestamptz not null default now()
);

-- updated_at 자동 갱신
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists trg_app_state_touch on public.app_state;
create trigger trg_app_state_touch before update on public.app_state for each row execute function public.touch_updated_at();

-- 가입 시 프로필 자동 생성 (카카오 닉네임·이메일 반영)
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, email, provider)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'name', new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'nickname', new.raw_user_meta_data->>'preferred_username'),
          new.email,
          new.raw_app_meta_data->>'provider')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- 직원 여부 헬퍼
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;

-- 5) 행 단위 보안 (RLS): 임대인은 자기 행만, 직원은 전체 열람
alter table public.profiles     enable row level security;
alter table public.app_state    enable row level security;
alter table public.staff        enable row level security;
alter table public.extract_logs enable row level security;

drop policy if exists "profiles: own" on public.profiles;
create policy "profiles: own" on public.profiles for all using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists "profiles: staff read" on public.profiles;
create policy "profiles: staff read" on public.profiles for select using (public.is_staff());

drop policy if exists "app_state: own" on public.app_state;
create policy "app_state: own" on public.app_state for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "app_state: staff read" on public.app_state;
create policy "app_state: staff read" on public.app_state for select using (public.is_staff());

drop policy if exists "staff: self read" on public.staff;
create policy "staff: self read" on public.staff for select using (auth.uid() = user_id or public.is_staff());

drop policy if exists "extract_logs: own insert" on public.extract_logs;
create policy "extract_logs: own insert" on public.extract_logs for insert with check (auth.uid() = user_id);
drop policy if exists "extract_logs: staff read" on public.extract_logs;
create policy "extract_logs: staff read" on public.extract_logs for select using (public.is_staff() or auth.uid() = user_id);

-- 6) 회사용 뷰: JSON 상태를 표로 펼쳐 Table Editor 에서 바로 보기
create or replace view public.v_landlords as
select p.id as user_id, p.name, p.email, p.phone, p.provider,
       s.data->'landlord'->>'name'     as landlord_name,
       s.data->'landlord'->>'bizNo'    as biz_no,
       s.data->'landlord'->>'bizName'  as biz_name,
       s.data->'landlord'->>'taxType'  as tax_type,
       jsonb_array_length(coalesce(s.data->'contracts','[]'::jsonb)) as contracts,
       s.updated_at as last_sync
from public.profiles p left join public.app_state s on s.user_id = p.id;

create or replace view public.v_contracts as
select s.user_id,
       c->>'id'            as contract_id,
       c->>'name'          as property_name,
       c->>'type'          as property_type,
       c->>'addr'          as address,
       (c->>'area')::numeric   as area_m2,
       c->>'tenant'        as tenant,
       c->>'tenantBiz'     as tenant_biz_no,
       c->>'tenantBizName' as tenant_biz_name,
       (c->>'deposit')::numeric as deposit,
       (c->>'rent')::numeric    as monthly_rent,
       (c->>'mgmt')::numeric    as mgmt_fee,
       (c->>'vatSeparate')::boolean as vat_separate,
       (c->>'payDay')::int     as pay_day,
       (c->>'start')::date     as lease_start,
       (c->>'end')::date       as lease_end,
       (c->>'autoRegistered')::boolean as auto_registered,
       s.updated_at
from public.app_state s, jsonb_array_elements(coalesce(s.data->'contracts','[]'::jsonb)) c;

create or replace view public.v_rent_payments as
select s.user_id, split_part(k.key,'_',1) as contract_id, split_part(k.key,'_',2) as year_month,
       k.value->>'paidAt' as paid_at, (k.value->>'amount')::numeric as amount
from public.app_state s, jsonb_each(coalesce(s.data->'rents','{}'::jsonb)) k;

create or replace view public.v_invoices as
select s.user_id, split_part(k.key,'_',1) as contract_id, split_part(k.key,'_',2) as year_month,
       k.value->>'status' as status, k.value->>'approvalNo' as approval_no, k.value->>'issuedAt' as issued_at
from public.app_state s, jsonb_each(coalesce(s.data->'invoices','{}'::jsonb)) k;

-- 뷰는 기본 테이블의 RLS를 따르도록 (호출자 권한으로 실행)
alter view public.v_landlords     set (security_invoker = on);
alter view public.v_contracts     set (security_invoker = on);
alter view public.v_rent_payments set (security_invoker = on);
alter view public.v_invoices      set (security_invoker = on);

-- 7) 계약서 사진 저장소 (비공개 버킷, 경로: <user_id>/<contract_id>/<n>.jpg)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contract-photos', 'contract-photos', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880;

drop policy if exists "photos: own" on storage.objects;
create policy "photos: own" on storage.objects for all
  using (bucket_id = 'contract-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'contract-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "photos: staff read" on storage.objects;
create policy "photos: staff read" on storage.objects for select
  using (bucket_id = 'contract-photos' and public.is_staff());

-- 완료 표시
select 'rentkeeper schema ready' as status;
