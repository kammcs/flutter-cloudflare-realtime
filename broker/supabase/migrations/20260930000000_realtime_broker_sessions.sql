-- Session registry for the cloudflare_realtime reference broker.
--
-- The broker (the realtime-broker Edge Function) records which room and which
-- user created each Cloudflare SFU session. It uses the table to bind sessions
-- to their creator and to restrict pulls to the same room.
--
-- Only the service role may touch it: RLS is on with no policies, and the
-- anon and authenticated roles have no privileges. The service role bypasses
-- RLS.

create table if not exists public.realtime_broker_sessions (
  session_id text primary key,
  room_id    text        not null,
  owner_id   text        not null,
  created_at timestamptz not null,
  expires_at timestamptz not null
);

create index if not exists realtime_broker_sessions_expires_at_idx
  on public.realtime_broker_sessions (expires_at);

alter table public.realtime_broker_sessions enable row level security;

revoke all on table public.realtime_broker_sessions from public, anon, authenticated;
grant select, insert, delete on table public.realtime_broker_sessions to service_role;

comment on table public.realtime_broker_sessions is
  'cloudflare_realtime broker: SFU session -> room and owner. Service role only.';

-- Expired rows are ignored by the broker. To delete them periodically, enable
-- the pg_cron extension and schedule, for example:
--
--   select cron.schedule(
--     'realtime-broker-sessions-cleanup',
--     '17 * * * *',
--     $$delete from public.realtime_broker_sessions where expires_at < now()$$
--   );
