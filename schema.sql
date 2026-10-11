-- LEGACY MVP BASELINE SCHEMA — retained for reference only.
-- For existing Haven projects, do NOT rerun this file: it is not idempotent.
-- Use supabase/migrations/20261011_haven_phase2.sql as the safe bootstrap/upgrade path.
-- HAVEN GLOBAL MVP — Supabase SQL Editor
-- Review before applying to a live project. Enable RLS on every exposed table.
create extension if not exists pgcrypto;

create type public.property_status as enum ('draft','pending_review','published','rejected','suspended');
create type public.booking_status as enum ('requested','accepted','declined','cancelled','completed','refunded');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  avatar_url text,
  country_code text,
  preferred_currency text not null default 'USD',
  role text not null default 'guest' check (role in ('guest','host','staff')),
  created_at timestamptz not null default now()
);

create table public.properties (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  description text not null default '',
  city text not null,
  country text not null default '',
  country_code text,
  address_private text,
  property_type text not null default 'Apartment',
  currency char(3) not null default 'USD',
  price_per_night numeric(12,2) not null check (price_per_night > 0),
  max_guests int not null default 2 check (max_guests between 1 and 100),
  bedrooms int not null default 1 check (bedrooms >= 0),
  bathrooms numeric(4,1) not null default 1 check (bathrooms >= 0),
  image_url text,
  amenities jsonb not null default '[]'::jsonb,
  quality_score int check (quality_score between 0 and 100),
  verification_status text not null default 'not_reviewed' check (verification_status in ('not_reviewed','submitted','in_review','verified','rejected','expired')),
  verification_notes text,
  status public.property_status not null default 'draft',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index properties_public_search_idx on public.properties(status,country_code,city);
create index properties_host_idx on public.properties(host_id,created_at desc);

create table public.property_evidence (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id) on delete cascade,
  submitted_by uuid not null references auth.users(id) on delete cascade,
  room_type text not null,
  storage_path text,
  evidence_kind text not null default 'photo' check (evidence_kind in ('photo','video','inspection','document')),
  captured_at timestamptz,
  reviewer_status text not null default 'pending' check (reviewer_status in ('pending','accepted','rejected')),
  reviewer_notes text,
  created_at timestamptz not null default now()
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  guest_id uuid not null references auth.users(id) on delete cascade,
  host_id uuid not null references auth.users(id),
  check_in date not null,
  check_out date not null,
  guests int not null default 1 check (guests > 0),
  currency char(3) not null,
  nightly_rate numeric(12,2) not null check (nightly_rate > 0),
  nights int generated always as (check_out - check_in) stored,
  subtotal numeric(12,2) not null check (subtotal > 0),
  platform_fee numeric(12,2) not null check (platform_fee >= 0),
  payment_processing_fee numeric(12,2) not null default 0,
  status public.booking_status not null default 'requested',
  payment_provider text,
  payment_reference text,
  created_at timestamptz not null default now(),
  constraint valid_booking_dates check (check_out > check_in)
);
create index bookings_guest_idx on public.bookings(guest_id,created_at desc);
create index bookings_host_idx on public.bookings(host_id,created_at desc);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  property_id uuid not null references public.properties(id) on delete cascade,
  guest_id uuid not null references auth.users(id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  review_text text not null default '',
  created_at timestamptz not null default now()
);

create table public.safety_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  checkin_interval_hours int not null default 12 check (checkin_interval_hours in (6,12,24,48)),
  trusted_contact_name text,
  trusted_contact_method text,
  consent_at timestamptz,
  escalation_instructions text,
  updated_at timestamptz not null default now()
);

create table public.safety_checkins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete set null,
  scheduled_for timestamptz not null,
  confirmed_at timestamptz,
  state text not null default 'scheduled' check (state in ('scheduled','confirmed','missed','reviewed','closed')),
  created_at timestamptz not null default now()
);

create table public.waitlist (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check (position('@' in email) > 1),
  created_at timestamptz not null default now()
);

-- Profile rows created for new accounts. Users may only update their own profile.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name',''));
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.properties enable row level security;
alter table public.property_evidence enable row level security;
alter table public.bookings enable row level security;
alter table public.reviews enable row level security;
alter table public.safety_preferences enable row level security;
alter table public.safety_checkins enable row level security;
alter table public.waitlist enable row level security;

create policy "Profiles visible to owner" on public.profiles for select to authenticated using (auth.uid() = id);
create policy "Profiles insert by owner" on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "Profiles update by owner" on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

create policy "Published properties are public" on public.properties for select to anon, authenticated using (status = 'published');
create policy "Hosts view own properties" on public.properties for select to authenticated using (host_id = auth.uid());
create policy "Hosts create own drafts" on public.properties for insert to authenticated with check (host_id = auth.uid() and status = 'draft');
create policy "Hosts update own unpublished properties" on public.properties for update to authenticated using (host_id = auth.uid() and status in ('draft','rejected')) with check (host_id = auth.uid() and status in ('draft','pending_review','rejected'));
create policy "Hosts delete own drafts" on public.properties for delete to authenticated using (host_id = auth.uid() and status = 'draft');

create policy "Host manages evidence" on public.property_evidence for all to authenticated using (submitted_by = auth.uid()) with check (submitted_by = auth.uid());
create policy "Guest sees own bookings" on public.bookings for select to authenticated using (guest_id = auth.uid());
create policy "Host sees bookings for own properties" on public.bookings for select to authenticated using (host_id = auth.uid());
create policy "Guest creates own booking request" on public.bookings for insert to authenticated with check (guest_id = auth.uid() and status = 'requested' and platform_fee >= 0);
create policy "Guest cancels own requested booking" on public.bookings for update to authenticated using (guest_id = auth.uid() and status = 'requested') with check (guest_id = auth.uid() and status = 'cancelled');
create policy "Review visible to everyone" on public.reviews for select to anon, authenticated using (true);
create policy "Guest creates review for own completed booking" on public.reviews for insert to authenticated with check (guest_id = auth.uid() and exists (select 1 from public.bookings b where b.id = booking_id and b.guest_id = auth.uid() and b.status = 'completed'));
create policy "Owner manages own safety preferences" on public.safety_preferences for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Owner manages own checkins" on public.safety_checkins for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Waitlist insertion is public by design; do not put other personal data in this table.
create policy "Anyone can join waitlist" on public.waitlist for insert to anon, authenticated with check (true);
-- No public SELECT policy for waitlist: emails are not publicly readable.

-- IMPORTANT:
-- Do not allow browsers to set a property to 'published' or mark it 'verified'.
-- Implement moderation, booking price calculations, payment confirmation and payout logic
-- in trusted server-side code / Supabase Edge Functions before production.
-- The 5% platform fee is a proposed business rule, not a payment integration.
