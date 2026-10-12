-- Terrastep — Postgres schema (Supabase-ready)
-- Source: Terrastep Product & Technical Plan, Section 15 (data model and
-- access boundaries) and Section 17 (atomic acceptance).
--
-- Access model:
--   * End users authenticate via Supabase Auth; auth.uid() is the user id.
--   * profiles_public is the ONLY table with a sanitized public read.
--   * Fitness, evidence and ledger tables are owner-read / service-write.
--   * The referee (service role) is the only writer of contributions,
--     cell_ownership and ownership_events. A service key must NEVER ship
--     in the app (Section 15).
--   * H3 ids are text at API boundaries (JavaScript-safe), stored as text.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- identity
create table if not exists profiles_public (
    user_id        uuid primary key,               -- = auth.users.id
    nickname       text not null unique check (char_length(nickname) between 2 and 24),
    avatar_ref     text,
    kingdom_name   text check (char_length(kingdom_name) <= 40),
    kingdom_color  text check (kingdom_color ~ '^#[0-9A-Fa-f]{6}$'),
    moderation_state text not null default 'ok' check (moderation_state in ('ok','flagged','suspended')),
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

create table if not exists profiles_private (
    user_id        uuid primary key references profiles_public(user_id) on delete cascade,
    weight_kg      numeric(5,2) check (weight_kg > 0),
    units          text not null default 'metric' check (units in ('metric','imperial')),
    language       text not null default 'en',
    weekly_goal_walks int check (weekly_goal_walks between 1 and 14),
    hide_calories  boolean not null default false,
    competition_opt_in boolean not null default false,  -- separate public opt-in (Section 19)
    consent_version text,
    settings       jsonb not null default '{}'::jsonb,
    updated_at     timestamptz not null default now()
);

create table if not exists devices (
    installation_id uuid primary key,
    user_id        uuid not null references profiles_public(user_id) on delete cascade,
    app_version    text,
    key_ref        text,
    risk_state     text not null default 'normal',
    created_at     timestamptz not null default now(),
    last_seen_at   timestamptz
);

-- ---------------------------------------------------------------- sessions
create table if not exists sessions (
    id             uuid primary key,
    user_id        uuid not null references profiles_public(user_id) on delete cascade,
    installation_id uuid references devices(installation_id),
    activity       text not null default 'walk' check (activity in ('walk')),
    status         text not null default 'recording'
                   check (status in ('draft','recording','paused','locally_finished',
                                     'uploading','verifying','verified','partially_verified','closed')),
    rules_version  text not null,
    ticket_expires_at timestamptz not null,
    started_at     timestamptz not null,
    ended_at       timestamptz,
    recorded_distance_m numeric(10,1) not null default 0,
    recorded_moving_ms  bigint not null default 0,
    verified_micro      bigint not null default 0,
    created_at     timestamptz not null default now()
);

create table if not exists evidence_batches (
    id             bigint generated always as identity primary key,
    session_id     uuid not null references sessions(id) on delete cascade,
    batch_id       text not null,                       -- client idempotency key part
    seq_from       int not null,
    seq_to         int not null,
    digest         text not null,                       -- sha256 of canonical payload
    payload_ref    jsonb,                               -- restricted; expires (Section 19)
    expires_at     timestamptz not null,                -- default ingest + 72h
    received_at    timestamptz not null default now(),
    receipt        jsonb not null,                      -- canonical stored receipt (Section 17 step 2)
    unique (session_id, batch_id)
);

-- ---------------------------------------------------------------- game ledger
create table if not exists leagues_and_seasons (
    id             text primary key,                    -- e.g. 'abbottabad-s01'
    region_name    text not null,
    timezone       text not null default 'Asia/Karachi',
    rules_version  text not null,
    starts_at      timestamptz not null,
    ends_at        timestamptz not null,
    region_cells   text[] not null default '{}'         -- versioned pilot cell set (Section 11)
);

create table if not exists contributions (
    id             bigint generated always as identity primary key,  -- acceptance sequence
    user_id        uuid not null references profiles_public(user_id) on delete cascade,
    session_id     uuid not null references sessions(id) on delete cascade,
    season_id      text not null references leagues_and_seasons(id),
    h3_cell        text not null,
    league_day     date not null,
    activity_start timestamptz not null,
    credited_micro bigint not null check (credited_micro > 0),
    rules_version  text not null,
    created_at     timestamptz not null default now()
);
create index if not exists contributions_cell_idx on contributions (season_id, h3_cell, user_id, activity_start);
create index if not exists contributions_user_day_idx on contributions (user_id, league_day);

create table if not exists cell_ownership (
    season_id      text not null references leagues_and_seasons(id),
    h3_cell        text not null,
    owner_id       uuid not null references profiles_public(user_id) on delete cascade,
    version        bigint not null default 1,
    evaluated_at   timestamptz not null default now(),
    primary key (season_id, h3_cell)                    -- one owner per cell (Section 21 invariant)
);

create table if not exists ownership_events (
    id             bigint generated always as identity primary key,
    season_id      text not null,
    h3_cell        text not null,
    prev_owner_id  uuid,
    new_owner_id   uuid,
    cause          text not null check (cause in ('capture','takeover','decay_release','fraud_reversal')),
    rules_version  text not null,
    created_at     timestamptz not null default now()
);

create table if not exists daily_fitness (
    user_id        uuid not null references profiles_public(user_id) on delete cascade,
    local_day      date not null,
    source         text not null default 'recorded',
    distance_m     numeric(10,1) not null default 0,
    moving_ms      bigint not null default 0,
    steps          int,
    est_active_kcal numeric(8,1),
    revision       int not null default 1,
    primary key (user_id, local_day, source)
);

-- ---------------------------------------------------------------- trust & safety
create table if not exists reports_and_blocks (
    id             bigint generated always as identity primary key,
    reporter_id    uuid not null references profiles_public(user_id) on delete cascade,
    subject_user_id uuid references profiles_public(user_id) on delete set null,
    h3_cell        text,
    category       text not null check (category in ('content','cheating','unsafe_cell','other')),
    detail         text,
    action         text not null default 'open',
    created_at     timestamptz not null default now()
);

create table if not exists privacy_exclusions (
    id             bigint generated always as identity primary key,
    user_id        uuid not null references profiles_public(user_id) on delete cascade,
    h3_cell        text not null,                       -- every cell intersecting the zone (Section 19)
    created_at     timestamptz not null default now(),
    unique (user_id, h3_cell)
);

create table if not exists outbox_and_receipts (
    idempotency_key text primary key,
    response       jsonb not null,
    event_state    text not null default 'stored',
    created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------- row-level security
alter table profiles_public   enable row level security;
alter table profiles_private  enable row level security;
alter table devices           enable row level security;
alter table sessions          enable row level security;
alter table evidence_batches  enable row level security;
alter table contributions     enable row level security;
alter table cell_ownership    enable row level security;
alter table daily_fitness     enable row level security;
alter table reports_and_blocks enable row level security;
alter table privacy_exclusions enable row level security;

-- Public projection: anyone may read the SANITIZED public profile only.
create policy profiles_public_read on profiles_public for select using (true);
create policy profiles_public_self_write on profiles_public for update
    using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Private data: owner only. Service role bypasses RLS for the referee.
create policy profiles_private_owner on profiles_private for all
    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy devices_owner on devices for all
    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy sessions_owner_read on sessions for select using (user_id = auth.uid());
create policy contributions_owner_read on contributions for select using (user_id = auth.uid());
create policy daily_fitness_owner on daily_fitness for all
    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy reports_reporter_read on reports_and_blocks for select using (reporter_id = auth.uid());
create policy reports_reporter_insert on reports_and_blocks for insert with check (reporter_id = auth.uid());
create policy exclusions_owner on privacy_exclusions for all
    using (user_id = auth.uid()) with check (user_id = auth.uid());
-- evidence_batches and cell_ownership: no end-user policies -> service role only.
