-- Haven Phase 2 hardening migration.
-- Safe to run when original MVP tables already exist, or if setup stopped at profiles. Does not drop tables or user data.
create extension if not exists pgcrypto;

-- Bootstrap missing MVP tables as well. This makes the migration work if the original schema stopped at the existing profiles table.
do $$ begin create type public.property_status as enum ('draft','pending_review','published','rejected','suspended'); exception when duplicate_object then null; end $$;
do $$ begin create type public.booking_status as enum ('requested','accepted','declined','cancelled','completed','refunded'); exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text, avatar_url text, country_code text,
  preferred_currency text not null default 'USD',
  role text not null default 'guest' check (role in ('guest','host','staff')),
  created_at timestamptz not null default now()
);
create table if not exists public.properties (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120), description text not null default '',
  city text not null, country text not null default '', country_code text, address_private text,
  property_type text not null default 'Apartment', currency char(3) not null default 'USD',
  price_per_night numeric(12,2) not null check (price_per_night > 0),
  max_guests int not null default 2 check (max_guests between 1 and 100),
  bedrooms int not null default 1 check (bedrooms >= 0), bathrooms numeric(4,1) not null default 1 check (bathrooms >= 0),
  image_url text, amenities jsonb not null default '[]'::jsonb,
  quality_score int check (quality_score between 0 and 100),
  verification_status text not null default 'not_reviewed' check (verification_status in ('not_reviewed','submitted','in_review','verified','rejected','expired')),
  verification_notes text, status public.property_status not null default 'draft',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.property_evidence (
  id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id) on delete cascade,
  submitted_by uuid not null references auth.users(id) on delete cascade, room_type text not null,
  storage_path text, evidence_kind text not null default 'photo' check (evidence_kind in ('photo','video','inspection','document')),
  captured_at timestamptz, reviewer_status text not null default 'pending' check (reviewer_status in ('pending','accepted','rejected')),
  reviewer_notes text, created_at timestamptz not null default now()
);
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(), property_id uuid not null references public.properties(id),
  guest_id uuid not null references auth.users(id) on delete cascade, host_id uuid not null references auth.users(id),
  check_in date not null, check_out date not null, guests int not null default 1 check (guests > 0),
  currency char(3) not null, nightly_rate numeric(12,2) not null check (nightly_rate > 0),
  nights int generated always as (check_out - check_in) stored,
  subtotal numeric(12,2) not null check (subtotal > 0), platform_fee numeric(12,2) not null check (platform_fee >= 0),
  payment_processing_fee numeric(12,2) not null default 0, status public.booking_status not null default 'requested',
  payment_provider text, payment_reference text, created_at timestamptz not null default now(),
  constraint valid_booking_dates check (check_out > check_in)
);
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(), booking_id uuid not null unique references public.bookings(id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade, guest_id uuid not null references auth.users(id) on delete cascade,
  rating int not null check (rating between 1 and 5), review_text text not null default '', created_at timestamptz not null default now()
);
create table if not exists public.safety_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  checkin_interval_hours int not null default 12 check (checkin_interval_hours in (6,12,24,48)),
  trusted_contact_name text, trusted_contact_method text, consent_at timestamptz,
  escalation_instructions text, updated_at timestamptz not null default now()
);
create table if not exists public.safety_checkins (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete set null, scheduled_for timestamptz not null,
  confirmed_at timestamptz, state text not null default 'scheduled' check (state in ('scheduled','confirmed','missed','reviewed','closed')),
  created_at timestamptz not null default now()
);
create table if not exists public.waitlist (
  id uuid primary key default gen_random_uuid(), email text not null unique check (position('@' in email) > 1), created_at timestamptz not null default now()
);
create index if not exists properties_public_search_idx on public.properties(status,country_code,city);
create index if not exists properties_host_idx on public.properties(host_id,created_at desc);
create index if not exists bookings_guest_idx on public.bookings(guest_id,created_at desc);
create index if not exists bookings_host_idx on public.bookings(host_id,created_at desc);


alter table public.profiles
  add column if not exists full_name text,
  add column if not exists avatar_url text,
  add column if not exists country_code text,
  add column if not exists preferred_currency text not null default 'USD',
  add column if not exists role text not null default 'guest' check (role in ('guest','host','staff')),
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists locale text not null default 'en',
  add column if not exists timezone text not null default 'UTC',
  add column if not exists stripe_connect_account_id text,
  add column if not exists identity_status text not null default 'not_started'
    check (identity_status in ('not_started','pending','verified','rejected','expired'));

alter table public.properties
  add column if not exists guest_rules text not null default '',
  add column if not exists cancellation_policy text not null default 'moderate',
  add column if not exists minimum_nights integer not null default 1 check (minimum_nights > 0),
  add column if not exists maximum_nights integer check (maximum_nights is null or maximum_nights >= minimum_nights),
  add column if not exists check_in_time text not null default '15:00',
  add column if not exists check_out_time text not null default '11:00';

alter table public.bookings
  add column if not exists payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','checkout_created','paid','refunded','failed','partially_refunded')),
  add column if not exists guest_total numeric(12,2),
  add column if not exists host_payout_estimate numeric(12,2),
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancellation_reason text,
  add column if not exists paid_at timestamptz;

alter table public.safety_checkins
  add column if not exists reminder_sent_at timestamptz,
  add column if not exists contact_alerted_at timestamptz;

create table if not exists public.property_verifications (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  submitted_by uuid not null references auth.users(id) on delete cascade,
  provider text,
  provider_case_id text,
  status text not null default 'submitted' check (status in ('submitted','in_review','verified','rejected','expired')),
  identity_check_status text not null default 'not_started' check (identity_check_status in ('not_started','pending','verified','rejected','expired')),
  property_check_status text not null default 'not_started' check (property_check_status in ('not_started','pending','verified','rejected','expired')),
  evidence_summary text not null default '',
  reviewer_id uuid references auth.users(id),
  reviewer_notes text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists property_verifications_property_idx on public.property_verifications(property_id, created_at desc);

create table if not exists public.payment_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  provider_event_id text not null unique,
  booking_id uuid references public.bookings(id) on delete set null,
  event_type text not null,
  processed_at timestamptz not null default now(),
  safe_summary jsonb not null default '{}'::jsonb
);

create table if not exists public.safety_alert_log (
  id uuid primary key default gen_random_uuid(),
  checkin_id uuid references public.safety_checkins(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  alert_type text not null check (alert_type in ('guest_reminder','trusted_contact','worker_error')),
  channel text not null default 'email',
  recipient_redacted text,
  status text not null check (status in ('sent','failed','skipped')),
  detail text,
  created_at timestamptz not null default now()
);
create index if not exists safety_alert_log_user_idx on public.safety_alert_log(user_id, created_at desc);

alter table public.property_verifications enable row level security;
alter table public.payment_events enable row level security;
alter table public.safety_alert_log enable row level security;
alter table public.profiles enable row level security;
alter table public.properties enable row level security;
alter table public.property_evidence enable row level security;
alter table public.bookings enable row level security;
alter table public.reviews enable row level security;
alter table public.safety_preferences enable row level security;
alter table public.safety_checkins enable row level security;
alter table public.waitlist enable row level security;

drop policy if exists "Profiles visible to owner" on public.profiles;
drop policy if exists "Profiles insert by owner" on public.profiles;
drop policy if exists "Profiles update by owner" on public.profiles;
create policy "Profiles visible to owner" on public.profiles for select to authenticated using (id=(select auth.uid()));
create policy "Profiles update by owner" on public.profiles for update to authenticated using (id=(select auth.uid())) with check (id=(select auth.uid()));
-- Users must not be able to promote themselves to staff or change payment/verification provider IDs.
revoke update on public.profiles from authenticated;
grant update (full_name, avatar_url, country_code, preferred_currency, locale, timezone) on public.profiles to authenticated;
revoke select on public.profiles from anon, authenticated;
grant select (id, full_name, avatar_url, country_code, preferred_currency, role, created_at, locale, timezone, identity_status) on public.profiles to authenticated;
-- Keep the private street address and internal reviewer notes out of the public PostgREST surface.
revoke select on public.properties from anon, authenticated;
grant select (id, title, description, city, country, country_code, property_type, currency, price_per_night, max_guests, bedrooms, bathrooms, image_url, amenities, quality_score, verification_status, status, created_at, updated_at, guest_rules, cancellation_policy, minimum_nights, maximum_nights, check_in_time, check_out_time) on public.properties to anon, authenticated;

drop policy if exists "Published properties are public" on public.properties;
drop policy if exists "Hosts view own properties" on public.properties;
drop policy if exists "Hosts create own drafts" on public.properties;
drop policy if exists "Hosts update own unpublished properties" on public.properties;
drop policy if exists "Hosts delete own drafts" on public.properties;
create policy "Published properties are public" on public.properties for select to anon,authenticated using (status='published');
create policy "Hosts view own properties" on public.properties for select to authenticated using (host_id=(select auth.uid()));
create policy "Hosts create own drafts" on public.properties for insert to authenticated with check (host_id=(select auth.uid()) and status='draft' and verification_status<>'verified' and quality_score is null);
create policy "Hosts update own unpublished properties" on public.properties for update to authenticated using (host_id=(select auth.uid()) and status in ('draft','rejected')) with check (host_id=(select auth.uid()) and status in ('draft','pending_review','rejected') and verification_status<>'verified' and quality_score is null);
create policy "Hosts delete own drafts" on public.properties for delete to authenticated using (host_id=(select auth.uid()) and status='draft');

drop policy if exists "Guest sees own bookings" on public.bookings;
drop policy if exists "Host sees bookings for own properties" on public.bookings;
create policy "Guest sees own bookings" on public.bookings for select to authenticated using (guest_id=(select auth.uid()));
create policy "Host sees bookings for own properties" on public.bookings for select to authenticated using (host_id=(select auth.uid()));

drop policy if exists "Review visible to everyone" on public.reviews;
drop policy if exists "Guest creates review for own completed booking" on public.reviews;
create policy "Review visible to everyone" on public.reviews for select to anon,authenticated using (true);
create policy "Guest creates review for own completed booking" on public.reviews for insert to authenticated with check (guest_id=(select auth.uid()) and exists(select 1 from public.bookings b where b.id=booking_id and b.guest_id=(select auth.uid()) and b.status='completed'));

drop policy if exists "Owner manages own safety preferences" on public.safety_preferences;
create policy "Owner manages own safety preferences" on public.safety_preferences for all to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
drop policy if exists "Anyone can join waitlist" on public.waitlist;
create policy "Anyone can join waitlist" on public.waitlist for insert to anon,authenticated with check (true);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name) values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name','')) on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

-- Do not let hosts self-approve evidence or edit reviewer decisions.
drop policy if exists "Host manages evidence" on public.property_evidence;
drop policy if exists "Host reads own evidence" on public.property_evidence;
drop policy if exists "Host submits evidence for own draft" on public.property_evidence;
create policy "Host reads own evidence" on public.property_evidence
  for select to authenticated using (
    submitted_by = (select auth.uid()) or exists (
      select 1 from public.properties p where p.id = property_id and p.host_id = (select auth.uid())
    )
  );
create policy "Host submits evidence for own draft" on public.property_evidence
  for insert to authenticated with check (
    submitted_by = (select auth.uid()) and exists (
      select 1 from public.properties p where p.id = property_id and p.host_id = (select auth.uid()) and p.status in ('draft','pending_review','rejected')
    ) and reviewer_status='pending' and reviewer_notes is null
  );

-- Hosts/guests can read verification status for their own property; only trusted server/admin code can change review decisions.
drop policy if exists "Owners read property verification cases" on public.property_verifications;
drop policy if exists "Hosts submit verification case" on public.property_verifications;
create policy "Owners read property verification cases" on public.property_verifications
  for select to authenticated using (
    submitted_by = (select auth.uid()) or exists (
      select 1 from public.properties p where p.id = property_id and p.host_id = (select auth.uid())
    )
  );
create policy "Hosts submit verification case" on public.property_verifications
  for insert to authenticated with check (
    submitted_by = (select auth.uid()) and exists (
      select 1 from public.properties p where p.id = property_id and p.host_id = (select auth.uid())
    ) and status='submitted' and identity_check_status='not_started' and property_check_status='not_started' and provider is null and provider_case_id is null and reviewer_id is null and reviewer_notes is null and reviewed_at is null
  );
-- No client policies for payment_events or safety_alert_log: service-role only.

-- Remove direct client booking creation. Booking totals are computed inside the database.
drop policy if exists "Guest creates own booking request" on public.bookings;
drop policy if exists "Guest cancels own requested booking" on public.bookings;

create or replace function public.request_booking(
  p_property_id uuid,
  p_check_in date,
  p_check_out date,
  p_guests integer default 1
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_property public.properties%rowtype;
  v_nights integer;
  v_subtotal numeric(12,2);
  v_fee numeric(12,2);
  v_booking_id uuid;
begin
  if v_user is null then raise exception 'Please sign in before requesting a booking.' using errcode = '28000'; end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then
    raise exception 'Check-out must be after check-in.' using errcode = '22007';
  end if;
  if p_check_in < current_date then raise exception 'Check-in date cannot be in the past.' using errcode = '22007'; end if;
  if p_guests is null or p_guests < 1 then raise exception 'Guest count must be at least one.' using errcode = '22023'; end if;

  select * into v_property from public.properties where id = p_property_id for update;
  if not found or v_property.status <> 'published' then raise exception 'This property is not currently bookable.' using errcode = 'P0002'; end if;
  if v_property.host_id = v_user then raise exception 'You cannot book your own property.' using errcode = '22023'; end if;
  if p_guests > v_property.max_guests then raise exception 'Guest count exceeds this property limit.' using errcode = '22023'; end if;

  v_nights := p_check_out - p_check_in;
  if v_nights < v_property.minimum_nights then raise exception 'This property requires a longer minimum stay.' using errcode = '22023'; end if;
  if v_property.maximum_nights is not null and v_nights > v_property.maximum_nights then raise exception 'This stay exceeds the property maximum.' using errcode = '22023'; end if;

  if exists (
    select 1 from public.bookings b
    where b.property_id = p_property_id
      and (b.status = 'accepted' or (b.status = 'requested' and b.created_at > now() - interval '24 hours'))
      and daterange(b.check_in, b.check_out, '[)') && daterange(p_check_in, p_check_out, '[)')
  ) then raise exception 'Those dates are no longer available. Please choose other dates.' using errcode = '23P01'; end if;

  v_subtotal := round(v_property.price_per_night * v_nights, 2);
  v_fee := round(v_subtotal * 0.05, 2);
  insert into public.bookings(property_id, guest_id, host_id, check_in, check_out, guests, currency, nightly_rate, subtotal, platform_fee, guest_total, host_payout_estimate, status, payment_status)
  values (v_property.id, v_user, v_property.host_id, p_check_in, p_check_out, p_guests, v_property.currency, v_property.price_per_night, v_subtotal, v_fee, v_subtotal, v_subtotal - v_fee, 'requested', 'unpaid')
  returning id into v_booking_id;

  return jsonb_build_object('booking_id',v_booking_id,'nights',v_nights,'currency',v_property.currency,
    'nightly_rate',v_property.price_per_night,'subtotal',v_subtotal,'haven_fee',v_fee,
    'guest_total_before_taxes_and_payment_fees',v_subtotal,'host_estimate_before_other_costs',v_subtotal-v_fee,
    'status','requested','payment_status','unpaid');
end;
$$;
revoke all on function public.request_booking(uuid,date,date,integer) from public;
grant execute on function public.request_booking(uuid,date,date,integer) to authenticated;

create or replace function public.cancel_booking(p_booking_id uuid, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_booking public.bookings%rowtype;
begin
  if auth.uid() is null then raise exception 'Please sign in.' using errcode = '28000'; end if;
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found or v_booking.guest_id <> auth.uid() then raise exception 'Booking not found for this account.' using errcode = 'P0002'; end if;
  if v_booking.status not in ('requested','accepted') or v_booking.payment_status <> 'unpaid' then
    raise exception 'This booking cannot be cancelled in its current state. Contact support if you need help.' using errcode = '22023';
  end if;
  update public.bookings set status='cancelled',cancelled_at=now(),cancellation_reason=left(coalesce(p_reason,''),500) where id=p_booking_id;
  return jsonb_build_object('booking_id',p_booking_id,'status','cancelled');
end;
$$;
revoke all on function public.cancel_booking(uuid,text) from public;
grant execute on function public.cancel_booking(uuid,text) to authenticated;

create or replace function public.respond_to_booking(p_booking_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_booking public.bookings%rowtype;
begin
  if auth.uid() is null then raise exception 'Please sign in.' using errcode = '28000'; end if;
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found.' using errcode = 'P0002'; end if;
  if v_booking.host_id <> auth.uid() then raise exception 'Only this listing host can respond.' using errcode = '42501'; end if;
  if v_booking.status <> 'requested' then raise exception 'This booking request has already been handled.' using errcode = '22023'; end if;
  if p_accept then
    if exists (select 1 from public.bookings b where b.property_id = v_booking.property_id and b.id <> v_booking.id and b.status = 'accepted' and daterange(b.check_in,b.check_out,'[)') && daterange(v_booking.check_in,v_booking.check_out,'[)')) then
      raise exception 'Those dates have been taken by another accepted booking.' using errcode = '23P01';
    end if;
    update public.bookings set status = 'accepted' where id = p_booking_id;
  else
    update public.bookings set status = 'declined' where id = p_booking_id;
  end if;
  return jsonb_build_object('booking_id',p_booking_id,'status',case when p_accept then 'accepted' else 'declined' end);
end;
$$;
revoke all on function public.respond_to_booking(uuid,boolean) from public;
grant execute on function public.respond_to_booking(uuid,boolean) to authenticated;

-- Only the owner can confirm a check-in; clients cannot mark it missed or alert a contact directly.
drop policy if exists "Owner manages own checkins" on public.safety_checkins;
drop policy if exists "Owner reads own checkins" on public.safety_checkins;
create policy "Owner reads own checkins" on public.safety_checkins
  for select to authenticated using (user_id = (select auth.uid()));

create or replace function public.confirm_havencheck(p_checkin_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_booking_id uuid; v_interval integer; v_next_id uuid; v_next_at timestamptz;
begin
  if auth.uid() is null then raise exception 'Please sign in.' using errcode = '28000'; end if;
  update public.safety_checkins set state='confirmed', confirmed_at=now()
  where id=p_checkin_id and user_id=auth.uid() and state='scheduled' and scheduled_for <= now() + interval '24 hours'
  returning id,booking_id into v_id,v_booking_id;
  if v_id is null then raise exception 'Check-in not found or cannot be confirmed.' using errcode = 'P0002'; end if;
  if v_booking_id is not null and exists (
    select 1 from public.bookings b where b.id=v_booking_id and b.guest_id=auth.uid() and b.status='accepted' and b.payment_status='paid' and current_date >= b.check_in and current_date < b.check_out
  ) then
    select checkin_interval_hours into v_interval from public.safety_preferences where user_id=auth.uid();
    v_interval := coalesce(v_interval,12);
    v_next_at := now() + make_interval(hours => v_interval);
    insert into public.safety_checkins(user_id,booking_id,scheduled_for,state) values(auth.uid(),v_booking_id,v_next_at,'scheduled') returning id into v_next_id;
  end if;
  return jsonb_build_object('checkin_id',v_id,'state','confirmed','next_checkin_id',v_next_id,'next_scheduled_for',v_next_at);
end;
$$;
revoke all on function public.confirm_havencheck(uuid) from public;
grant execute on function public.confirm_havencheck(uuid) to authenticated;

-- Storage: listing photos are public; evidence documents stay private.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('haven-listing-images','haven-listing-images',true,10485760,array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('haven-property-evidence','haven-property-evidence',false,15728640,array['image/jpeg','image/png','image/webp','application/pdf','video/mp4'])
on conflict (id) do nothing;

drop policy if exists "Public can view Haven listing images" on storage.objects;
drop policy if exists "Hosts upload own listing images" on storage.objects;
drop policy if exists "Hosts update own listing images" on storage.objects;
drop policy if exists "Hosts delete own listing images" on storage.objects;
create policy "Public can view Haven listing images" on storage.objects for select to anon,authenticated using (bucket_id='haven-listing-images');
create policy "Hosts upload own listing images" on storage.objects for insert to authenticated with check (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Hosts update own listing images" on storage.objects for update to authenticated using (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text) with check (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Hosts delete own listing images" on storage.objects for delete to authenticated using (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text);

drop policy if exists "Hosts upload own private evidence" on storage.objects;
drop policy if exists "Hosts read own private evidence" on storage.objects;
drop policy if exists "Hosts delete own private evidence" on storage.objects;
create policy "Hosts upload own private evidence" on storage.objects for insert to authenticated with check (bucket_id='haven-property-evidence' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Hosts read own private evidence" on storage.objects for select to authenticated using (bucket_id='haven-property-evidence' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Hosts delete own private evidence" on storage.objects for delete to authenticated using (bucket_id='haven-property-evidence' and (storage.foldername(name))[1]=(select auth.uid())::text);

-- This migration intentionally does not create public policies for payment or safety audit logs.
-- Run in Supabase SQL Editor after the original schema. It is additive and does not delete existing data.


create or replace function public.disable_havencheck()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Please sign in.' using errcode = '28000'; end if;
  update public.safety_preferences set consent_at=null,trusted_contact_name=null,trusted_contact_method=null,updated_at=now() where user_id=auth.uid();
  update public.safety_checkins set state='closed' where user_id=auth.uid() and state='scheduled';
  return jsonb_build_object('disabled',true);
end;
$$;
revoke all on function public.disable_havencheck() from public;
grant execute on function public.disable_havencheck() to authenticated;

create or replace function public.start_havencheck(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_booking public.bookings%rowtype; v_interval integer; v_checkin_id uuid; v_scheduled timestamptz;
begin
  if auth.uid() is null then raise exception 'Please sign in.' using errcode = '28000'; end if;
  select * into v_booking from public.bookings where id=p_booking_id and guest_id=auth.uid() for update;
  if not found then raise exception 'Booking not found for this account.' using errcode = 'P0002'; end if;
  if v_booking.status <> 'accepted' or v_booking.payment_status <> 'paid' or current_date < v_booking.check_in or current_date >= v_booking.check_out then
    raise exception 'HavenCheck can be started for an accepted booking during the stay dates.' using errcode = '22023';
  end if;
  select checkin_interval_hours into v_interval from public.safety_preferences where user_id=auth.uid();
  v_interval := coalesce(v_interval,12);
  select id into v_checkin_id from public.safety_checkins where user_id=auth.uid() and booking_id=p_booking_id and state='scheduled' limit 1;
  if v_checkin_id is not null then
    select scheduled_for into v_scheduled from public.safety_checkins where id=v_checkin_id;
    return jsonb_build_object('checkin_id',v_checkin_id,'scheduled_for',v_scheduled,'interval_hours',v_interval,'already_scheduled',true);
  end if;
  v_scheduled := now() + make_interval(hours => v_interval);
  insert into public.safety_checkins(user_id,booking_id,scheduled_for,state)
    values (auth.uid(),p_booking_id,v_scheduled,'scheduled') returning id into v_checkin_id;
  return jsonb_build_object('checkin_id',v_checkin_id,'scheduled_for',v_scheduled,'interval_hours',v_interval);
end;
$$;
revoke all on function public.start_havencheck(uuid) from public;
grant execute on function public.start_havencheck(uuid) to authenticated;
