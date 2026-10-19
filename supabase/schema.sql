-- =============================================================================
-- Kavach — Supabase schema
-- Run once in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run.
-- Safe to re-run: every object is created idempotently.
--
-- What it creates
--   profiles            one row per auth user (auto-created on sign-up)
--   watchlist           companies a user follows, with a personal alert threshold
--   portfolios          named portfolios ...
--   portfolio_holdings  ... and their weighted holdings
--   analyses            saved "Analyze a company" runs (inputs + model output)
--   assistant_queries   Ask-Kavach history (optional, powers "recent questions")
--
-- Security: Row Level Security is ON for every table; a user can only ever see
-- and change their own rows. The anon key is safe to ship in the app.
-- =============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  full_name           text check (char_length(full_name) <= 120),
  organisation        text check (char_length(organisation) <= 160),
  role                text check (role in ('analyst', 'credit_officer', 'investor', 'treasury', 'student', 'other')),
  preferred_language  text not null default 'en'
                      check (preferred_language in ('en','as','bn','brx','doi','gu','hi','kn','ks','kok','mai',
                                                    'ml','mni','mr','ne','or','pa','sa','sat','sd','ta','te','ur')),
  theme               text not null default 'dark' check (theme in ('dark', 'light', 'system')),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- auto-create a profile when someone signs up (reads metadata sent by the app)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, organisation, role, preferred_language)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'organisation', ''),
    case when new.raw_user_meta_data ->> 'role' in ('analyst','credit_officer','investor','treasury','student','other')
         then new.raw_user_meta_data ->> 'role' end,
    coalesce(nullif(new.raw_user_meta_data ->> 'preferred_language', ''), 'en')
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- watchlist
-- ---------------------------------------------------------------------------
create table if not exists public.watchlist (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  company_id       text not null check (company_id ~ '^[A-Za-z0-9_-]{1,32}$'),
  company_name     text,
  note             text check (char_length(note) <= 500),
  alert_threshold  numeric(5,4) not null default 0.10 check (alert_threshold > 0 and alert_threshold < 1),
  pd_at_add        numeric(6,5) check (pd_at_add between 0 and 1),
  created_at       timestamptz not null default now(),
  unique (user_id, company_id)
);
create index if not exists watchlist_user_idx on public.watchlist (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- portfolios + holdings
-- ---------------------------------------------------------------------------
create table if not exists public.portfolios (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 80),
  description text check (char_length(description) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, name)
);
create index if not exists portfolios_user_idx on public.portfolios (user_id);
drop trigger if exists portfolios_updated_at on public.portfolios;
create trigger portfolios_updated_at before update on public.portfolios
  for each row execute function public.set_updated_at();

create table if not exists public.portfolio_holdings (
  id            uuid primary key default gen_random_uuid(),
  portfolio_id  uuid not null references public.portfolios (id) on delete cascade,
  company_id    text not null check (company_id ~ '^[A-Za-z0-9_-]{1,32}$'),
  company_name  text,
  weight        numeric(9,6) not null check (weight > 0),
  exposure_cr   numeric(14,2) check (exposure_cr >= 0),   -- optional INR crore exposure
  created_at    timestamptz not null default now(),
  unique (portfolio_id, company_id)
);
create index if not exists holdings_portfolio_idx on public.portfolio_holdings (portfolio_id);

-- ---------------------------------------------------------------------------
-- analyses (real companies scored through "Analyze")
-- ---------------------------------------------------------------------------
create table if not exists public.analyses (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  company_name   text not null check (char_length(company_name) between 1 and 160),
  sector         text,
  fiscal_year    int check (fiscal_year between 1990 and 2100),
  input          jsonb not null,                 -- statements + counterparties as submitted
  result         jsonb not null,                 -- full model output at the time
  pd_12m         numeric(6,5) not null check (pd_12m between 0 and 1),
  risk_band      text not null check (risk_band in ('LOW', 'MODERATE', 'HIGH', 'CRITICAL')),
  implied_rating text,
  model_version  text not null default 'kavach-irgnn-1',
  created_at     timestamptz not null default now()
);
create index if not exists analyses_user_idx on public.analyses (user_id, created_at desc);
create index if not exists analyses_name_idx on public.analyses (user_id, lower(company_name));

-- ---------------------------------------------------------------------------
-- workspace: the user's real companies (all fiscal years) + their relationships
-- ---------------------------------------------------------------------------
create table if not exists public.workspace_companies (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  company_name     text not null check (char_length(company_name) between 1 and 160),
  sector           text,
  promoter_pledge  numeric(6,5) not null default 0 check (promoter_pledge between 0 and 1),
  defaulted        smallint check (defaulted in (0, 1)),          -- known outcome, used for retraining
  years            jsonb not null check (jsonb_typeof(years) = 'array' and jsonb_array_length(years) between 1 and 30),
  source           text not null default 'manual' check (source in ('manual', 'upload', 'ticker', 'pdf')),
  created_at       timestamptz not null default now(),
  unique (user_id, company_name)
);
create index if not exists workspace_companies_user_idx on public.workspace_companies (user_id);

create table if not exists public.workspace_links (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  company       text not null,
  counterparty  text not null,
  relation      text not null check (relation in ('supplier', 'customer', 'parent', 'subsidiary', 'guarantor', 'peer')),
  share         numeric(6,5) not null check (share > 0 and share <= 1),
  health        text not null default 'stable' check (health in ('strong', 'stable', 'weak', 'distressed')),
  created_at    timestamptz not null default now()
);
create index if not exists workspace_links_user_idx on public.workspace_links (user_id);

-- ---------------------------------------------------------------------------
-- assistant history
-- ---------------------------------------------------------------------------
create table if not exists public.assistant_queries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  question    text not null check (char_length(question) <= 1000),
  intent      text,
  answer      text,
  lang        text not null default 'en',
  via_voice   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists assistant_user_idx on public.assistant_queries (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Row Level Security: owner-only access everywhere
-- ---------------------------------------------------------------------------
alter table public.profiles           enable row level security;
alter table public.watchlist          enable row level security;
alter table public.portfolios         enable row level security;
alter table public.portfolio_holdings enable row level security;
alter table public.analyses           enable row level security;
alter table public.assistant_queries  enable row level security;
alter table public.workspace_companies enable row level security;
alter table public.workspace_links    enable row level security;

-- profiles: read / update your own row (insert happens via the trigger)
drop policy if exists "profiles: own row read"   on public.profiles;
drop policy if exists "profiles: own row update" on public.profiles;
create policy "profiles: own row read"   on public.profiles for select to authenticated using (id = auth.uid());
create policy "profiles: own row update" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- simple owner tables
do $$
declare t text;
begin
  foreach t in array array['watchlist', 'portfolios', 'analyses', 'assistant_queries', 'workspace_companies', 'workspace_links'] loop
    execute format('drop policy if exists "%1$s: owner select" on public.%1$I', t);
    execute format('drop policy if exists "%1$s: owner insert" on public.%1$I', t);
    execute format('drop policy if exists "%1$s: owner update" on public.%1$I', t);
    execute format('drop policy if exists "%1$s: owner delete" on public.%1$I', t);
    execute format('create policy "%1$s: owner select" on public.%1$I for select to authenticated using (user_id = auth.uid())', t);
    execute format('create policy "%1$s: owner insert" on public.%1$I for insert to authenticated with check (user_id = auth.uid())', t);
    execute format('create policy "%1$s: owner update" on public.%1$I for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('create policy "%1$s: owner delete" on public.%1$I for delete to authenticated using (user_id = auth.uid())', t);
  end loop;
end $$;

-- holdings: allowed when the parent portfolio belongs to you
drop policy if exists "holdings: via own portfolio" on public.portfolio_holdings;
create policy "holdings: via own portfolio" on public.portfolio_holdings for all to authenticated
  using (exists (select 1 from public.portfolios p where p.id = portfolio_id and p.user_id = auth.uid()))
  with check (exists (select 1 from public.portfolios p where p.id = portfolio_id and p.user_id = auth.uid()));

-- table privileges for the authenticated role (anon gets nothing)
revoke all on public.profiles, public.watchlist, public.portfolios, public.portfolio_holdings,
              public.analyses, public.assistant_queries, public.workspace_companies, public.workspace_links from anon;
grant select, update                 on public.profiles           to authenticated;
grant select, insert, update, delete on public.watchlist          to authenticated;
grant select, insert, update, delete on public.portfolios         to authenticated;
grant select, insert, update, delete on public.portfolio_holdings to authenticated;
grant select, insert, update, delete on public.analyses           to authenticated;
grant select, insert, update, delete on public.assistant_queries  to authenticated;
grant select, insert, update, delete on public.workspace_companies to authenticated;
grant select, insert, update, delete on public.workspace_links     to authenticated;
