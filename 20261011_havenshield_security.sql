-- HavenShield additive migration. Run after existing Haven migrations.
-- No existing Haven tables are dropped. Exact coordinates are never publicly readable.
create table if not exists public.safety_contacts (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 contact_name text not null check (length(trim(contact_name)) between 1 and 100),
 email text, phone_e164 text, whatsapp_e164 text,
 consent_at timestamptz not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check (email is not null or phone_e164 is not null or whatsapp_e164 is not null)
);
create unique index if not exists safety_contacts_one_per_user on public.safety_contacts(user_id);
create index if not exists safety_contacts_owner_idx on public.safety_contacts(user_id);

create table if not exists public.safety_incidents (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 booking_id uuid references public.bookings(id) on delete set null,
 checkin_id uuid references public.safety_checkins(id) on delete set null,
 incident_type text not null check (incident_type in ('sos','missed_checkin','other')),
 status text not null default 'open' check (status in ('open','acknowledged','contact_attempted','escalated','resolved','false_alarm')),
 urgency text not null default 'urgent' check (urgency in ('urgent','high','standard')),
 summary text not null default '', created_at timestamptz not null default now(), acknowledged_at timestamptz, resolved_at timestamptz,
 acknowledged_by uuid references auth.users(id), resolved_by uuid references auth.users(id), notifications_started_at timestamptz, updated_at timestamptz not null default now()
);
create unique index if not exists safety_incidents_checkin_once on public.safety_incidents(checkin_id);
create index if not exists safety_incidents_open_idx on public.safety_incidents(status,created_at desc);
create index if not exists safety_incidents_owner_idx on public.safety_incidents(user_id,created_at desc);

create table if not exists public.safety_location_sessions (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 booking_id uuid references public.bookings(id) on delete set null,
 consent_at timestamptz not null, expires_at timestamptz not null,
 revoked_at timestamptz, created_at timestamptz not null default now(),
 check (expires_at > consent_at), check (expires_at <= consent_at + interval '24 hours')
);
create index if not exists safety_location_sessions_active_idx on public.safety_location_sessions(user_id,expires_at) where revoked_at is null;

create table if not exists public.safety_location_updates (
 id bigint generated always as identity primary key, session_id uuid not null references public.safety_location_sessions(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 latitude double precision not null check (latitude between -90 and 90), longitude double precision not null check (longitude between -180 and 180),
 accuracy_m double precision check (accuracy_m is null or accuracy_m between 0 and 100000), captured_at timestamptz not null default now(),
 created_at timestamptz not null default now()
);
create index if not exists safety_location_updates_session_idx on public.safety_location_updates(session_id,captured_at desc);

create table if not exists public.safety_responders (
 user_id uuid primary key references auth.users(id) on delete cascade,
 active boolean not null default true, display_name text not null, created_at timestamptz not null default now(),
 granted_by uuid references auth.users(id), revoked_at timestamptz
);
create table if not exists public.safety_audit_log (
 id bigint generated always as identity primary key, actor_user_id uuid references auth.users(id) on delete set null,
 incident_id uuid references public.safety_incidents(id) on delete set null,
 action text not null, detail jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create table if not exists public.safety_notification_attempts (
 id uuid primary key default gen_random_uuid(), incident_id uuid references public.safety_incidents(id) on delete set null,
 checkin_id uuid references public.safety_checkins(id) on delete set null, user_id uuid references auth.users(id) on delete set null,
 recipient_type text not null check (recipient_type in ('guest','trusted_contact','safety_team')),
 channel text not null check (channel in ('email','sms','web_push')),
 recipient_redacted text, status text not null check (status in ('queued','sent','delivered','failed','skipped')),
 provider_message_id text, attempt_no int not null default 1, error_code text, created_at timestamptz not null default now()
);
create index if not exists safety_notification_incident_idx on public.safety_notification_attempts(incident_id,created_at desc);

alter table public.safety_contacts enable row level security;
alter table public.safety_incidents enable row level security;
alter table public.safety_location_sessions enable row level security;
alter table public.safety_location_updates enable row level security;
alter table public.safety_responders enable row level security;
alter table public.safety_audit_log enable row level security;
alter table public.safety_notification_attempts enable row level security;

-- Guests can manage only their own trusted contacts. They cannot forge consent timestamps.
drop policy if exists safety_contacts_owner_select on public.safety_contacts;
create policy safety_contacts_owner_select on public.safety_contacts for select to authenticated using (user_id=(select auth.uid()));
drop policy if exists safety_contacts_owner_insert on public.safety_contacts;
create policy safety_contacts_owner_insert on public.safety_contacts for insert to authenticated with check (user_id=(select auth.uid()) and consent_at <= now());
drop policy if exists safety_contacts_owner_update on public.safety_contacts;
create policy safety_contacts_owner_update on public.safety_contacts for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()) and consent_at <= now());
drop policy if exists safety_contacts_owner_delete on public.safety_contacts;
create policy safety_contacts_owner_delete on public.safety_contacts for delete to authenticated using (user_id=(select auth.uid()));

-- Incident records are created/updated through Edge Functions only; guests may read their own incidents.
drop policy if exists safety_incidents_owner_read on public.safety_incidents;
create policy safety_incidents_owner_read on public.safety_incidents for select to authenticated using (user_id=(select auth.uid()));
drop policy if exists safety_location_sessions_owner_read on public.safety_location_sessions;
create policy safety_location_sessions_owner_read on public.safety_location_sessions for select to authenticated using (user_id=(select auth.uid()));
drop policy if exists safety_location_updates_owner_read on public.safety_location_updates;
create policy safety_location_updates_owner_read on public.safety_location_updates for select to authenticated using (user_id=(select auth.uid()));
-- Responders, audit logs and notification attempts are service-role/server-only. No client policies.
revoke all on public.safety_responders, public.safety_audit_log, public.safety_notification_attempts from anon, authenticated;
revoke insert, update, delete on public.safety_incidents, public.safety_location_sessions, public.safety_location_updates from anon, authenticated;
grant select on public.safety_incidents, public.safety_location_sessions, public.safety_location_updates to authenticated;
grant select, insert, update, delete on public.safety_contacts to authenticated;

-- Create/replace a contact preference row only through own authenticated identity.
create or replace function public.havenshield_save_preferences(p_interval_hours int default 12)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required.' using errcode='28000'; end if;
 if p_interval_hours not in (12,24) then raise exception 'Choose 12 or 24 hours.' using errcode='22023'; end if;
 insert into public.safety_preferences(user_id,checkin_interval_hours,updated_at)
 values(auth.uid(),p_interval_hours,now()) on conflict(user_id) do update set checkin_interval_hours=excluded.checkin_interval_hours,updated_at=now();
 return jsonb_build_object('saved',true,'interval_hours',p_interval_hours);
end $$;
revoke all on function public.havenshield_save_preferences(int) from public;
grant execute on function public.havenshield_save_preferences(int) to authenticated;

-- Staff membership must be granted manually by the project owner in SQL, never by a client.
comment on table public.safety_responders is 'Server-only allowlist. Only project owner/service role should grant responder access.';
comment on table public.safety_location_updates is 'Precise location data; apply retention policy and do not expose to hosts or public clients.';
