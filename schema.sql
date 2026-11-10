-- FURI GUILD MANAGER / Supabase PostgreSQL schema
create extension if not exists pgcrypto;

create table if not exists public.profiles(
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null default '',
 username text unique,
 role text not null default 'member' check(role in ('군주','부군주','간부진','총무','부총무','담당자','member')),
 approved boolean not null default false,
 member_id uuid,
 created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists username text unique;
create table if not exists public.members(
 id uuid primary key default gen_random_uuid(),
 legacy_no integer,
 character_name text not null,
 character_class text not null default '기사',
 status text not null default '신규' check(status in ('신규','활동','휴식','탈퇴','복귀','검토필요')),
 joined_at date,
 left_at date,
 linked_profile_id uuid references public.profiles(id),
 created_at timestamptz not null default now(),
 unique(character_name)
);
alter table public.profiles drop constraint if exists profiles_member_id_fkey;
alter table public.profiles add constraint profiles_member_id_fkey foreign key(member_id) references public.members(id);
create table if not exists public.boss_events(
 id uuid primary key default gen_random_uuid(),
 boss_name text not null,
 event_date date not null,
 event_time time not null,
 status text not null default 'scheduled' check(status in ('scheduled','recruiting','confirmed','completed','cancelled')),
 notes text default '',
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.attendance(
 id uuid primary key default gen_random_uuid(),
 boss_event_id uuid not null references public.boss_events(id),
 member_id uuid not null references public.members(id),
 signup_status text not null default 'applied',
 attendance_status text not null default 'pending' check(attendance_status in ('pending','attended','late','partial','absent')),
 points_awarded integer not null default 0,
 confirmed_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 unique(boss_event_id,member_id)
);
create table if not exists public.loot_items(
 id uuid primary key default gen_random_uuid(),
 boss_event_id uuid references public.boss_events(id),
 item_name text not null,
 quantity integer not null default 1 check(quantity>0),
 acquired_at date not null default current_date,
 reference_price bigint not null default 0,
 status text not null default 'held' check(status in ('held','auctioning','sold','distributed','guild_owned')),
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.settlements(
 id uuid primary key default gen_random_uuid(),
 boss_event_id uuid references public.boss_events(id),
 gross_amount bigint not null check(gross_amount>=0),
 fund_rate numeric(5,4) not null default 0.20 check(fund_rate=0.20),
 fund_amount bigint not null,
 distribution_amount bigint not null,
 unallocated_amount bigint not null default 0,
 status text not null default 'pending' check(status in ('pending','approved','paid','cancelled')),
 note text default '',
 created_by uuid references auth.users(id),
 approved_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.settlement_shares(
 id uuid primary key default gen_random_uuid(),
 settlement_id uuid not null references public.settlements(id),
 member_id uuid not null references public.members(id),
 amount bigint not null check(amount>=0),
 status text not null default 'pending' check(status in ('pending','paid')),
 paid_at timestamptz,
 unique(settlement_id,member_id)
);
create table if not exists public.operating_fund_transactions(
 id uuid primary key default gen_random_uuid(),
 direction text not null check(direction in ('income','expense')),
 amount bigint not null check(amount>0),
 category text not null,
 description text default '',
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 source_settlement_id uuid references public.settlements(id),
 created_by uuid references auth.users(id),
 approved_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.auctions(
 id uuid primary key default gen_random_uuid(),
 loot_item_id uuid not null references public.loot_items(id),
 reserve_price bigint not null check(reserve_price>=0),
 winning_member_id uuid references public.members(id),
 winning_bid bigint,
 status text not null default 'open' check(status in ('open','closed','paid','delivered','cancelled')),
 opened_at timestamptz not null default now(),
 closed_at timestamptz,
 approved_by uuid references auth.users(id)
);
create table if not exists public.auction_bids(
 id uuid primary key default gen_random_uuid(),
 auction_id uuid not null references public.auctions(id),
 member_id uuid not null references public.members(id),
 bid_amount bigint not null check(bid_amount>=0),
 created_at timestamptz not null default now()
);
create table if not exists public.activity_scores(
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references public.members(id),
 boss_event_id uuid references public.boss_events(id),
 activity_type text not null check(activity_type in ('boss','siege','other')),
 points integer not null,
 note text default '',
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.audit_logs(
 id bigint generated always as identity primary key,
 actor_id uuid references auth.users(id),
 action text not null,
 table_name text not null,
 record_id uuid,
 before_data jsonb,
 after_data jsonb,
 created_at timestamptz not null default now()
);

create or replace function public.current_role() returns text language sql stable security definer set search_path=public as $$
 select coalesce((select role from public.profiles where id=auth.uid() and approved=true),'member');
$$;
create or replace function public.is_approved() returns boolean language sql stable security definer set search_path=public as $$
 select coalesce((select approved from public.profiles where id=auth.uid()),false);
$$;
create or replace function public.is_staff() returns boolean language sql stable security definer set search_path=public as $$
 select public.current_role() in ('군주','부군주','간부진','총무','부총무','담당자');
$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select public.current_role() in ('군주','부군주');
$$;

-- Account profile auto-creation. Approval and role assignment remain an admin action.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,display_name,username,role,approved)
 values(new.id,
 coalesce(new.raw_user_meta_data->>'display_name',split_part(new.email,'@',1)),
 coalesce(new.raw_user_meta_data->>'username',split_part(new.email,'@',1)),
 'member',false)
 on conflict(id) do nothing;
 return new;
end;$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

-- One transaction: exact 20% fund, equal split among eligible actual participants.
create or replace function public.create_settlement(
 p_boss_event_id uuid,
 p_gross_amount bigint,
 p_member_ids uuid[],
 p_note text default ''
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_count integer; v_fund bigint; v_pool bigint; v_share bigint; v_left bigint; v_sid uuid;
begin
 if not public.is_staff() then raise exception '실무 운영진 권한이 필요합니다.'; end if;
 if p_gross_amount<=0 then raise exception '판매금액은 0보다 커야 합니다.'; end if;
 select count(distinct u.member_id) into v_count from unnest(p_member_ids) as u(member_id)
 join public.members m on m.id=u.member_id and m.status in ('활동','복귀','신규');
 if v_count=0 then raise exception '분배 대상 참여자가 없습니다.'; end if;
 v_fund:=floor(p_gross_amount*0.20);
 v_pool:=p_gross_amount-v_fund;
 v_share:=floor(v_pool/v_count);
 v_left:=v_pool-(v_share*v_count);
 insert into public.settlements(boss_event_id,gross_amount,fund_rate,fund_amount,distribution_amount,unallocated_amount,note,created_by)
 values(p_boss_event_id,p_gross_amount,0.20,v_fund,v_pool,v_left,p_note,auth.uid()) returning id into v_sid;
 insert into public.settlement_shares(settlement_id,member_id,amount)
 select v_sid,x,v_share from (select distinct unnest(p_member_ids) x) s
 join public.members m on m.id=s.x and m.status in ('활동','복귀','신규');
 insert into public.operating_fund_transactions(direction,amount,category,description,status,source_settlement_id,created_by,approved_by)
 values('income',v_fund,'보스 아이템 판매 적립','정산 자동 적립 20%','approved',v_sid,auth.uid(),auth.uid());
 return jsonb_build_object('settlement_id',v_sid,'gross_amount',p_gross_amount,'fund_amount',v_fund,'distribution_amount',v_pool,'participants',v_count,'per_person',v_share,'unallocated_amount',v_left);
end;$$;

-- Auction bids must meet the operator-set reserve; highest bid is selected at close.
create or replace function public.place_auction_bid(p_auction_id uuid,p_member_id uuid,p_bid_amount bigint)
returns void language plpgsql security definer set search_path=public as $$
declare v_floor bigint; v_status text;
begin
 if not public.is_approved() then raise exception '승인된 계정만 입찰할 수 있습니다.'; end if;
 select reserve_price,status into v_floor,v_status from public.auctions where id=p_auction_id for update;
 if v_status<>'open' then raise exception '진행 중인 입찰이 아닙니다.'; end if;
 if p_bid_amount<v_floor then raise exception '운영진 기준가 미만으로 입찰할 수 없습니다.'; end if;
 insert into public.auction_bids(auction_id,member_id,bid_amount) values(p_auction_id,p_member_id,p_bid_amount);
end;$$;

alter table public.profiles enable row level security;
alter table public.members enable row level security;
alter table public.boss_events enable row level security;
alter table public.attendance enable row level security;
alter table public.loot_items enable row level security;
alter table public.settlements enable row level security;
alter table public.settlement_shares enable row level security;
alter table public.operating_fund_transactions enable row level security;
alter table public.auctions enable row level security;
alter table public.auction_bids enable row level security;
alter table public.activity_scores enable row level security;
alter table public.audit_logs enable row level security;

-- Members can see guild information and all member payout amounts, but only staff can mutate operational records.
create policy "profiles self or approved read" on public.profiles for select to authenticated using (id=auth.uid() or public.is_approved());
create policy "profiles admin update" on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "members read approved" on public.members for select to authenticated using (public.is_approved());
create policy "members staff insert" on public.members for insert to authenticated with check (public.is_staff());
create policy "members staff update" on public.members for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "boss read" on public.boss_events for select to authenticated using (public.is_approved());
create policy "boss staff write" on public.boss_events for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "attendance read" on public.attendance for select to authenticated using (public.is_approved());
create policy "attendance staff write" on public.attendance for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "items read" on public.loot_items for select to authenticated using (public.is_approved());
create policy "items staff write" on public.loot_items for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "settlements read" on public.settlements for select to authenticated using (public.is_approved());
create policy "settlements staff write" on public.settlements for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "shares all approved read" on public.settlement_shares for select to authenticated using (public.is_approved());
create policy "shares staff write" on public.settlement_shares for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "fund read approved" on public.operating_fund_transactions for select to authenticated using (public.is_approved());
create policy "fund staff insert" on public.operating_fund_transactions for insert to authenticated with check (public.is_admin());
create policy "fund admin update" on public.operating_fund_transactions for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "auction read" on public.auctions for select to authenticated using (public.is_approved());
create policy "auction staff write" on public.auctions for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "bids read approved" on public.auction_bids for select to authenticated using (public.is_approved());
create policy "bids approved insert" on public.auction_bids for insert to authenticated with check (public.is_approved());
create policy "scores read" on public.activity_scores for select to authenticated using (public.is_approved());
create policy "scores staff write" on public.activity_scores for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "audit admin read" on public.audit_logs for select to authenticated using (public.is_admin());
create policy "audit staff insert" on public.audit_logs for insert to authenticated with check (public.is_staff());

-- First-time bootstrap: create the first auth account in Supabase Auth, then run:
-- update public.profiles set role='군주', approved=true, display_name='군주' where id='YOUR_AUTH_USER_UUID';


-- Audit trail for operational changes. Audit rows are append-only from the application.
create or replace function public.audit_row_change() returns trigger language plpgsql security definer set search_path=public as $$
declare v_old jsonb; v_new jsonb; v_id uuid;
begin
 if tg_op='DELETE' then v_old:=to_jsonb(old); v_new:=null; v_id:=old.id;
 elsif tg_op='UPDATE' then v_old:=to_jsonb(old); v_new:=to_jsonb(new); v_id:=new.id;
 else v_old:=null; v_new:=to_jsonb(new); v_id:=new.id;
 end if;
 insert into public.audit_logs(actor_id,action,table_name,record_id,before_data,after_data)
 values(auth.uid(),tg_op,tg_table_name,v_id,v_old,v_new);
 if tg_op='DELETE' then return old; else return new; end if;
end;$$;
do $$ declare t text; begin
 foreach t in array array['members','boss_events','attendance','loot_items','settlements','settlement_shares','operating_fund_transactions','auctions','auction_bids','activity_scores','profiles']
 loop
  execute format('drop trigger if exists audit_%I on public.%I',t,t);
  execute format('create trigger audit_%I after insert or update or delete on public.%I for each row execute function public.audit_row_change()',t,t);
 end loop;
end $$;
grant execute on function public.create_settlement(uuid,bigint,uuid[],text) to authenticated;
grant execute on function public.place_auction_bid(uuid,uuid,bigint) to authenticated;
