-- Haven reliability upgrade: listing publishing, gallery access, guest contact fields and booking details.
-- Safe to run more than once on the existing Haven Phase 2 database. It does not delete existing records.

create extension if not exists pgcrypto;

alter table public.properties
  add column if not exists gallery_urls jsonb not null default '[]'::jsonb,
  add column if not exists neighborhood text,
  add column if not exists accessibility_notes text not null default '',
  add column if not exists address_private text,
  add column if not exists guest_rules text not null default '',
  add column if not exists cancellation_policy text not null default 'moderate',
  add column if not exists minimum_nights integer not null default 1,
  add column if not exists maximum_nights integer,
  add column if not exists check_in_time text not null default '15:00',
  add column if not exists check_out_time text not null default '11:00',
  add column if not exists updated_at timestamptz not null default now();

alter table public.bookings
  add column if not exists guest_phone text not null default '',
  add column if not exists guest_whatsapp text not null default '',
  add column if not exists guest_message text not null default '',
  add column if not exists arrival_time text not null default 'Not sure yet';

alter table public.profiles
  add column if not exists paystack_subaccount_code text,
  add column if not exists paystack_subaccount_active boolean not null default false;

-- Guests can see only public-safe property details; never grant the private street address.
revoke select on public.properties from anon, authenticated;
grant select (
  id, title, description, city, country, country_code, neighborhood, property_type, currency,
  price_per_night, max_guests, bedrooms, bathrooms, image_url, gallery_urls, amenities,
  quality_score, verification_status, status, created_at, updated_at, guest_rules,
  accessibility_notes, cancellation_policy, minimum_nights, maximum_nights, check_in_time, check_out_time
) on public.properties to anon, authenticated;
grant select (host_id) on public.properties to authenticated;
grant update (gallery_urls, image_url) on public.properties to authenticated;

-- Ensure listing images are in the expected public-read bucket. Uploads still require a signed-in host.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('haven-listing-images', 'haven-listing-images', true, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true, file_size_limit=10485760, allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "Public can view Haven listing images" on storage.objects;
drop policy if exists "Hosts upload own listing images" on storage.objects;
drop policy if exists "Hosts update own listing images" on storage.objects;
drop policy if exists "Hosts delete own listing images" on storage.objects;
create policy "Public can view Haven listing images" on storage.objects
  for select to anon, authenticated using (bucket_id='haven-listing-images');
create policy "Hosts upload own listing images" on storage.objects
  for insert to authenticated with check (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Hosts update own listing images" on storage.objects
  for update to authenticated using (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text)
  with check (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Hosts delete own listing images" on storage.objects
  for delete to authenticated using (bucket_id='haven-listing-images' and (storage.foldername(name))[1]=(select auth.uid())::text);

-- IMPORTANT: the public page filters status='published'. Setting verification_status='verified'
-- in Table Editor automatically publishes the property. 'verified' belongs in verification_status,
-- not in status (which uses draft/pending_review/published/rejected/suspended).
create or replace function public.haven_sync_property_publication_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.verification_status := lower(trim(coalesce(new.verification_status, 'not_reviewed')));
  new.updated_at := now();
  if new.status = 'suspended' then
    new.status := 'suspended';
  elsif new.verification_status = 'verified' then
    new.status := 'published';
  elsif new.verification_status = 'rejected' then
    new.status := 'rejected';
  elsif new.verification_status in ('submitted','in_review') and new.status not in ('suspended','published') then
    new.status := 'pending_review';
  end if;
  return new;
end;
$$;

drop trigger if exists haven_sync_property_publication_status_trigger on public.properties;
create trigger haven_sync_property_publication_status_trigger
before insert or update on public.properties
for each row execute function public.haven_sync_property_publication_status();

-- Keep the request function in sync with the richer booking form. Existing bookings remain unchanged.
drop function if exists public.request_booking(uuid, date, date, integer, text, text, text, text);
drop function if exists public.request_booking(uuid, date, date, integer, text);
drop function if exists public.request_booking(uuid, date, date, integer);
create function public.request_booking(
  p_property_id uuid,
  p_check_in date,
  p_check_out date,
  p_guests integer,
  p_guest_phone text,
  p_guest_whatsapp text,
  p_guest_message text default '',
  p_arrival_time text default 'Not sure yet'
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  v_property public.properties%rowtype;
  v_nights integer;
  v_subtotal numeric(12,2);
  v_fee numeric(12,2);
  v_booking_id uuid;
  v_phone text;
  v_whatsapp text;
begin
  if v_user is null then raise exception 'Please sign in before requesting a booking.' using errcode = '28000'; end if;
  v_phone := regexp_replace(coalesce(p_guest_phone, ''), '[^0-9+]', '', 'g');
  v_whatsapp := regexp_replace(coalesce(p_guest_whatsapp, ''), '[^0-9+]', '', 'g');
  if v_phone !~ '^\+?[0-9]{7,15}$' then raise exception 'Enter a valid phone number.' using errcode = '22023'; end if;
  if v_whatsapp !~ '^\+?[0-9]{7,15}$' then raise exception 'Enter a valid WhatsApp number.' using errcode = '22023'; end if;
  if length(coalesce(p_guest_message,'')) > 1000 then raise exception 'Host message must be 1000 characters or fewer.' using errcode = '22023'; end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then raise exception 'Check-out must be after check-in.' using errcode = '22007'; end if;
  if p_check_in < current_date then raise exception 'Check-in date cannot be in the past.' using errcode = '22007'; end if;
  if p_guests is null or p_guests < 1 then raise exception 'Guest count must be at least one.' using errcode = '22023'; end if;

  select * into v_property from public.properties where id = p_property_id for update;
  if not found or v_property.status <> 'published' then raise exception 'This property is not currently bookable.' using errcode = 'P0002'; end if;
  if v_property.host_id = v_user then raise exception 'You cannot book your own property.' using errcode = '22023'; end if;
  if p_guests > v_property.max_guests then raise exception 'Guest count exceeds this property limit.' using errcode = '22023'; end if;
  v_nights := p_check_out - p_check_in;
  if v_nights < coalesce(v_property.minimum_nights,1) then raise exception 'This property requires a longer minimum stay.' using errcode = '22023'; end if;
  if v_property.maximum_nights is not null and v_nights > v_property.maximum_nights then raise exception 'This stay exceeds the property maximum.' using errcode = '22023'; end if;
  if exists (
    select 1 from public.bookings b where b.property_id=p_property_id
      and (b.status='accepted' or (b.status='requested' and b.created_at>now()-interval '24 hours'))
      and daterange(b.check_in,b.check_out,'[)') && daterange(p_check_in,p_check_out,'[)')
  ) then raise exception 'Those dates are no longer available. Please choose other dates.' using errcode = '23P01'; end if;

  v_subtotal := round(v_property.price_per_night * v_nights, 2);
  v_fee := round(v_subtotal * 0.05, 2);
  insert into public.bookings(
    property_id, guest_id, host_id, guest_phone, guest_whatsapp, guest_message, arrival_time,
    check_in, check_out, guests, currency, nightly_rate, subtotal, platform_fee, guest_total,
    host_payout_estimate, status, payment_status
  ) values (
    v_property.id, v_user, v_property.host_id, v_phone, v_whatsapp, coalesce(p_guest_message,''), coalesce(p_arrival_time,'Not sure yet'),
    p_check_in, p_check_out, p_guests, v_property.currency, v_property.price_per_night, v_subtotal, v_fee,
    v_subtotal, v_subtotal-v_fee, 'requested', 'unpaid'
  ) returning id into v_booking_id;
  return jsonb_build_object(
    'booking_id',v_booking_id,'nights',v_nights,'currency',v_property.currency,
    'nightly_rate',v_property.price_per_night,'subtotal',v_subtotal,'haven_fee',v_fee,
    'guest_total_before_taxes_and_payment_fees',v_subtotal,'host_estimate_before_other_costs',v_subtotal-v_fee,
    'status','requested','payment_status','unpaid'
  );
end;
$$;
revoke all on function public.request_booking(uuid,date,date,integer,text,text,text,text) from public;
grant execute on function public.request_booking(uuid,date,date,integer,text,text,text,text) to authenticated;

-- Keep provider identifiers private to authenticated owners and server functions; browser grants do not include them.
revoke select on public.profiles from anon, authenticated;
grant select (id, full_name, avatar_url, country_code, preferred_currency, role, created_at, locale, timezone, identity_status) on public.profiles to authenticated;
