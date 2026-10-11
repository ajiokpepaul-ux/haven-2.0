-- Haven booking phone requirement. Safe for an existing Phase 2 database.
-- Existing bookings are preserved; old rows receive an empty phone until updated.
alter table public.bookings
  add column if not exists guest_phone text not null default '';

-- Remove both signatures so the browser cannot bypass the required phone field
-- by continuing to call the previous four-argument RPC.
drop function if exists public.request_booking(uuid, date, date, integer, text);
drop function if exists public.request_booking(uuid, date, date, integer);

create function public.request_booking(
  p_property_id uuid,
  p_check_in date,
  p_check_out date,
  p_guests integer,
  p_guest_phone text
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
begin
  if v_user is null then raise exception 'Please sign in before requesting a booking.' using errcode = '28000'; end if;
  v_phone := regexp_replace(coalesce(p_guest_phone, ''), '[^0-9+]', '', 'g');
  if v_phone !~ '^\+?[0-9]{7,15}$' then
    raise exception 'Enter a valid phone number (include country code where possible).' using errcode = '22023';
  end if;
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
  insert into public.bookings(
    property_id, guest_id, host_id, guest_phone, check_in, check_out, guests,
    currency, nightly_rate, subtotal, platform_fee, guest_total,
    host_payout_estimate, status, payment_status
  ) values (
    v_property.id, v_user, v_property.host_id, v_phone, p_check_in, p_check_out, p_guests,
    v_property.currency, v_property.price_per_night, v_subtotal, v_fee, v_subtotal,
    v_subtotal - v_fee, 'requested', 'unpaid'
  ) returning id into v_booking_id;

  return jsonb_build_object(
    'booking_id',v_booking_id,'nights',v_nights,'currency',v_property.currency,
    'nightly_rate',v_property.price_per_night,'subtotal',v_subtotal,'haven_fee',v_fee,
    'guest_total_before_taxes_and_payment_fees',v_subtotal,
    'host_estimate_before_other_costs',v_subtotal-v_fee,
    'status','requested','payment_status','unpaid'
  );
end;
$$;
revoke all on function public.request_booking(uuid,date,date,integer,text) from public;
grant execute on function public.request_booking(uuid,date,date,integer,text) to authenticated;
