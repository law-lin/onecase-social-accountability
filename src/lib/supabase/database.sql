drop table if exists public.users cascade;
drop table if exists public.cases cascade;
drop table if exists public.users_cases cascade;
drop table if exists public.tasks cascade;
drop table if exists public.updates cascade;
drop table if exists public.case_comments cascade;
drop table if exists public.user_roles cascade;
drop table if exists public.role_permissions cascade;

drop type if exists public.app_permission cascade;
drop type if exists public.app_role cascade;
drop type if exists public.user_status cascade;

drop function if exists public.authorize(app_permission, uuid) cascade;
drop function if exists public.handle_new_user() cascade;
-- Custom types
create type public.app_permission as enum ('cases.delete', 'case_comments.delete');
create type public.app_role as enum ('admin', 'moderator');
create type public.user_status as enum ('ONLINE', 'OFFLINE');

-- USERS
create table public.users (
  id              uuid not null primary key, -- UUID from auth.users
  first_name      text,
  last_name       text,
  username        text unique,
  email           text unique,
  phone           text unique,
  avatar_url      text,
  updated_at      timestamp with time zone,
  profile_created boolean default false,
  status      user_status default 'OFFLINE'::public.user_status
);
comment on table public.users is 'Profile data for each user.';
comment on column public.users.id is 'References the internal Supabase Auth user.';

-- CASES
create table public.cases (
  id            bigint generated by default as identity primary key,
  created_at    timestamp with time zone default timezone('utc'::text, now()) not null,
  index         int not null,
  title         text not null,  
  emoji         varchar not null,
  color         varchar not null,
  is_deletable  boolean default true, 
  is_clocked_in boolean default false,
  time_left     timestamp,
  created_by    uuid references public.users not null,
  unique(title, created_by),
  unique(emoji, created_by),
  unique(color, created_by)
);
comment on table public.cases is 'User created cases.';

-- USERS-CASES JUNCTION (case council members)
create table public.users_cases (
  user_id       uuid references public.users on delete cascade not null,
  case_id       bigint references public.cases on delete cascade not null
);

-- TASKS 
create table public.tasks (
  id            bigint generated by default as identity primary key,
  created_at    timestamp with time zone default timezone('utc'::text, now()) not null,
  title         text not null unique,
  description   text,       
  progress      real default 0 not null,
  created_by    uuid references public.users not null,
  case_id       bigint references public.cases on delete cascade
);
comment on table public.tasks is 'Tasks for each case';

-- UPDATES
create table public.updates (
  id            bigint generated by default as identity primary key,
  created_at    timestamp with time zone default timezone('utc'::text, now()) not null,
  title         text not null,
  old_progress  real not null,
  new_progress  real not null,
  created_by    uuid references public.users not null,
  task_id       bigint references public.tasks on delete cascade
);
comment on table public.updates is 'Updates for each task';

-- COMMENTS
create table public.case_comments (
  id            bigint generated by default as identity primary key,
  created_at    timestamp with time zone default timezone('utc'::text, now()) not null,
  message       text,
  is_update     boolean default false,
  user_id       uuid references public.users not null,
  case_id       bigint references public.cases on delete cascade not null
);
comment on table public.case_comments is 'Comment sent by a user for a case.';

-- USER ROLES
create table public.user_roles (
  user_id   uuid references public.users on delete cascade not null,
  role      app_role not null,
  unique (user_id, role)
);
comment on table public.user_roles is 'Application roles for each user.';

-- ROLE PERMISSIONS
create table public.role_permissions (
  role         app_role not null,
  permission   app_permission not null,
  unique (role, permission)
);
comment on table public.role_permissions is 'Application permissions for each role.';

-- authorize with role-based access control (RBAC)
create function public.authorize(
  requested_permission app_permission,
  user_id uuid
)
returns boolean as $$
declare
  bind_permissions int;
begin
  select count(*)
  from public.role_permissions
  inner join public.user_roles on role_permissions.role = user_roles.role
  where role_permissions.permission = authorize.requested_permission
    and user_roles.user_id = authorize.user_id
  into bind_permissions;
  
  return bind_permissions > 0;
end;
$$ language plpgsql security definer;

-- Secure the tables
alter table public.users enable row level security;
alter table public.cases enable row level security;
alter table public.users_cases enable row level security;
alter table public.tasks enable row level security;
alter table public.case_comments enable row level security;
alter table public.user_roles enable row level security;
alter table public.role_permissions enable row level security;

create policy "Allow logged-in read access" on public.users for select using ( true ); -- change this later
create policy "Allow individual insert access" on public.users for insert with check ( auth.uid() = id );
create policy "Allow individual update access" on public.users for update using ( auth.uid() = id or username = NULL );

create policy "Allow logged-in read access" on public.cases for select using ( auth.role() = 'authenticated' );
create policy "Allow individual insert access" on public.cases for insert with check ( auth.uid() = created_by );
create policy "Allow individual delete access" on public.cases for delete using ( auth.uid() = created_by and is_deletable = true);
create policy "Allow authorized delete access" on public.cases for delete using ( authorize('cases.delete', auth.uid()) and is_deletable = true);

create policy "Allow logged-in read access" on public.users_cases for select using ( auth.role() = 'authenticated' );
create policy "Allow individual insert access" on public.users_cases for insert with check ( case_id in (select case_id from public.cases where created_by = auth.uid()));
create policy "Allow individual delete access" on public.users_cases for delete using ( case_id in (select case_id from public.cases where created_by = auth.uid()) or auth.uid() = user_id ); -- let assignee remove themselves

create policy "Allow logged-in read access" on public.tasks for select using ( auth.role() = 'authenticated' );
create policy "Allow individual insert access" on public.tasks for insert with check ( auth.uid() = created_by );
create policy "Allow individual update access" on public.tasks for update using ( auth.uid() = created_by );
create policy "Allow individual delete access" on public.tasks for delete using ( auth.uid() = created_by );

create policy "Allow logged-in read access" on public.updates for select using ( auth.role() = 'authenticated' );
create policy "Allow individual insert access" on public.updates for insert with check ( auth.uid() = created_by );
create policy "Allow individual update access" on public.updates for update using ( auth.uid() = created_by );
create policy "Allow individual delete access" on public.updates for delete using ( auth.uid() = created_by );

create policy "Allow logged-in read access" on public.case_comments for select using ( auth.role() = 'authenticated' );
create policy "Allow individual insert access" on public.case_comments for insert with check ( auth.uid() = user_id );
create policy "Allow individual update access" on public.case_comments for update using ( auth.uid() = user_id );
create policy "Allow individual delete access" on public.case_comments for delete using ( auth.uid() = user_id );
create policy "Allow authorized delete access" on public.case_comments for delete using ( authorize('case_comments.delete', auth.uid()) );

create policy "Allow individual read access" on public.user_roles for select using ( auth.uid() = user_id );

-- Send "previous data" on change 
alter table public.users replica identity full; 
alter table public.cases replica identity full; 
alter table public.case_comments replica identity full;

-- inserts a row into public.users and assigns roles
create function public.handle_new_user() 
returns trigger as $$
declare is_admin boolean;
begin
  if new.phone is not null then
    insert into public.users (id, phone)
    values (new.id, new.phone);
  elsif new.email is not null then
    insert into public.users (id, email)
    values (new.id, new.email);
  else
    raise exception 'No phone or email provided';
  end if;
  
  insert into public.cases (index, title, emoji, color, is_deletable, created_by)
  values (0, 'Assigned Tasks', '🎯', '#FF6363', false, new.id);

  select count(*) = 1 from auth.users into is_admin;
  
  if position('+supaadmin@' in new.email) > 0 then
    insert into public.user_roles (user_id, role) values (new.id, 'admin');
  elsif position('+supamod@' in new.email) > 0 then
    insert into public.user_roles (user_id, role) values (new.id, 'moderator');
  end if;
  
  return new;
end;
$$ language plpgsql security definer;

-- trigger the function every time a user is created
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

/**
 * REALTIME SUBSCRIPTIONS
 * Only allow realtime listening on public tables.
 */

begin; 
  -- remove the realtime publication
  drop publication if exists supabase_realtime; 

  -- re-create the publication but don't enable it for any tables
  create publication supabase_realtime;  
commit;

-- add tables to the publication
alter publication supabase_realtime add table public.cases;
alter publication supabase_realtime add table public.case_comments;
alter publication supabase_realtime add table public.users;
