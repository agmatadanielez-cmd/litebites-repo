-- LiteBites Community setup
-- Run once in Supabase: SQL Editor -> New query -> paste this whole file -> Run.
-- Safe to run again: it skips or replaces what already exists.

-- 1. Tables --------------------------------------------------------------

-- Public name each student shows on their posts.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'LiteBites student'
    check (char_length(display_name) between 1 and 40),
  created_at timestamptz not null default now()
);

-- Moderators who can delete anyone's shared post.
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- Posts and private journal entries (shared = false means "Only me").
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  tag text not null default 'Progress'
    check (tag in ('Progress', 'Meal win', 'Tough day', 'Tip')),
  note text not null default '' check (char_length(note) <= 600),
  weight numeric(5, 1) check (weight is null or weight between 25 and 250),
  shared boolean not null default true,
  photo_path text
);
create index if not exists posts_created_at_idx on public.posts (created_at desc);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- 2. Access rules ---------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.admins enable row level security;
alter table public.posts enable row level security;

drop policy if exists "profiles: signed-in can read" on public.profiles;
create policy "profiles: signed-in can read" on public.profiles
  for select to authenticated using (true);
drop policy if exists "profiles: create own" on public.profiles;
create policy "profiles: create own" on public.profiles
  for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "admins: see own row" on public.admins;
create policy "admins: see own row" on public.admins
  for select to authenticated using (user_id = auth.uid());

-- Shared posts are visible to every signed-in student; "Only me" entries only to their author.
drop policy if exists "posts: read shared or own" on public.posts;
create policy "posts: read shared or own" on public.posts
  for select to authenticated using (shared or author = auth.uid());
drop policy if exists "posts: create own" on public.posts;
create policy "posts: create own" on public.posts
  for insert to authenticated with check (author = auth.uid());
drop policy if exists "posts: delete own or admin" on public.posts;
create policy "posts: delete own or admin" on public.posts
  for delete to authenticated using (author = auth.uid() or public.is_admin());

-- 3. Create a profile automatically when a student signs up ----------------

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(left(trim(new.raw_user_meta_data ->> 'display_name'), 40), ''), 'LiteBites student')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 4. Photo storage (private bucket; the app shows photos through short-lived links) --

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-photos', 'post-photos', false, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "post-photos: upload own" on storage.objects;
create policy "post-photos: upload own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'post-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "post-photos: read own or shared" on storage.objects;
create policy "post-photos: read own or shared" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'post-photos' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.posts p where p.photo_path = name and p.shared)
    )
  );

drop policy if exists "post-photos: delete own or admin" on storage.objects;
create policy "post-photos: delete own or admin" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'post-photos' and (
      (storage.foldername(name))[1] = auth.uid()::text or public.is_admin()
    )
  );

-- 5. Live updates ----------------------------------------------------------

do $$
begin
  alter publication supabase_realtime add table public.posts;
exception when duplicate_object then null;
end;
$$;

-- 6. Make yourself a moderator (optional) -----------------------------------
-- First sign up in the LiteBites Community tab, then replace the email below
-- with yours, select only these two lines and click Run.
--
-- insert into public.admins (user_id)
--   select id from auth.users where email = 'your-email@example.com';
