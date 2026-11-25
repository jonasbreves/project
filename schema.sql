-- =====================================================================
-- EXTENSÕES
-- =====================================================================
create extension if not exists "pgcrypto";

-- =====================================================================
-- TABELAS
-- =====================================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text,
  weight numeric,
  height numeric,
  avatar_url text,
  updated_at timestamptz default now()
);

create table if not exists public.habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  category text not null default 'habit' check (category in ('habit','workout')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.habit_logs (
  id uuid primary key default gen_random_uuid(),
  habit_id uuid not null references public.habits(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  log_date date not null,
  completed boolean not null default true,
  unique (habit_id, log_date)
);
create index if not exists habit_logs_user_date_idx on public.habit_logs (user_id, log_date);

create table if not exists public.goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade, -- NULL = meta compartilhada do casal
  title text not null,
  target_value numeric not null default 1,
  current_value numeric not null default 0,
  unit text default '',
  completed boolean not null default false
);

create table if not exists public.daily_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  note_date date not null,
  content text,
  unique (user_id, note_date)
);

create table if not exists public.weight_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  weight numeric not null,
  logged_at date not null default current_date,
  created_at timestamptz not null default now()
);

create table if not exists public.nudges (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  seen boolean not null default false
);

-- =====================================================================
-- TRIGGER: perfil + 3 hábitos padrão ao criar usuário
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;

  insert into public.habits (user_id, title, category, active)
  select new.id, t, 'habit', true
  from unnest(array['Hidratação', 'Sono regulado', 'Alimentação saudável']) as t;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill para usuários que já existam antes do trigger
insert into public.profiles (id, name)
select id, split_part(email, '@', 1) from auth.users
on conflict (id) do nothing;

insert into public.habits (user_id, title, category, active)
select p.id, t, 'habit', true
from public.profiles p
cross join unnest(array['Hidratação', 'Sono regulado', 'Alimentação saudável']) as t
where not exists (select 1 from public.habits h where h.user_id = p.id);

-- =====================================================================
-- RLS
-- =====================================================================
alter table public.profiles    enable row level security;
alter table public.habits      enable row level security;
alter table public.habit_logs  enable row level security;
alter table public.goals       enable row level security;
alter table public.daily_notes enable row level security;
alter table public.weight_logs enable row level security;
alter table public.nudges      enable row level security;

-- profiles
drop policy if exists "profiles_select" on public.profiles;
drop policy if exists "profiles_insert" on public.profiles;
drop policy if exists "profiles_update" on public.profiles;
drop policy if exists "profiles_delete" on public.profiles;
create policy "profiles_select" on public.profiles for select to authenticated using (true);
create policy "profiles_insert" on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "profiles_update" on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
create policy "profiles_delete" on public.profiles for delete to authenticated using (auth.uid() = id);

-- habits, habit_logs, daily_notes, weight_logs (registros próprios)
do $$
declare t text;
begin
  foreach t in array array['habits','habit_logs','daily_notes','weight_logs'] loop
    execute format('drop policy if exists "%1$s_select" on public.%1$s', t);
    execute format('drop policy if exists "%1$s_insert" on public.%1$s', t);
    execute format('drop policy if exists "%1$s_update" on public.%1$s', t);
    execute format('drop policy if exists "%1$s_delete" on public.%1$s', t);
    execute format('create policy "%1$s_select" on public.%1$s for select to authenticated using (true)', t);
    execute format('create policy "%1$s_insert" on public.%1$s for insert to authenticated with check (auth.uid() = user_id)', t);
    execute format('create policy "%1$s_update" on public.%1$s for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id)', t);
    execute format('create policy "%1$s_delete" on public.%1$s for delete to authenticated using (auth.uid() = user_id)', t);
  end loop;
end $$;

-- goals (próprias + compartilhadas com user_id NULL)
drop policy if exists "goals_select" on public.goals;
drop policy if exists "goals_insert" on public.goals;
drop policy if exists "goals_update" on public.goals;
drop policy if exists "goals_delete" on public.goals;
create policy "goals_select" on public.goals for select to authenticated using (true);
create policy "goals_insert" on public.goals for insert to authenticated
  with check (auth.uid() = user_id or user_id is null);
create policy "goals_update" on public.goals for update to authenticated
  using (auth.uid() = user_id or user_id is null)
  with check (auth.uid() = user_id or user_id is null);
create policy "goals_delete" on public.goals for delete to authenticated
  using (auth.uid() = user_id or user_id is null);

-- nudges
drop policy if exists "nudges_select" on public.nudges;
drop policy if exists "nudges_insert" on public.nudges;
drop policy if exists "nudges_update" on public.nudges;
create policy "nudges_select" on public.nudges for select to authenticated using (true);
create policy "nudges_insert" on public.nudges for insert to authenticated with check (auth.uid() = sender_id);
create policy "nudges_update" on public.nudges for update to authenticated
  using (auth.uid() = receiver_id) with check (auth.uid() = receiver_id);

-- =====================================================================
-- STORAGE: bucket público "avatars"
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

drop policy if exists "avatars_select" on storage.objects;
drop policy if exists "avatars_insert" on storage.objects;
drop policy if exists "avatars_update" on storage.objects;
drop policy if exists "avatars_delete" on storage.objects;

create policy "avatars_select" on storage.objects for select to authenticated
  using (bucket_id = 'avatars');
create policy "avatars_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars_update" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
