create extension if not exists pgcrypto;

do $$
begin
    create type public.school_role as enum ('headteacher', 'deputy_headteacher', 'staff', 'parent');
exception
    when duplicate_object then null;
end;
$$;

create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    email text not null unique,
    full_name text not null default '',
    role public.school_role not null default 'parent',
    created_at timestamptz not null default now()
);

create table if not exists public.students (
    id uuid primary key default gen_random_uuid(),
    admission_no text not null unique,
    full_name text not null,
    class_name text not null,
    is_active boolean not null default true,
    created_at timestamptz not null default now()
);

create table if not exists public.parent_students (
    parent_id uuid not null references public.profiles(id) on delete cascade,
    student_id uuid not null references public.students(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (parent_id, student_id)
);

create table if not exists public.staff_classes (
    id uuid primary key default gen_random_uuid(),
    staff_id uuid not null references public.profiles(id) on delete cascade,
    class_name text not null,
    subject text not null,
    created_at timestamptz not null default now(),
    unique (staff_id, class_name, subject)
);

create table if not exists public.attendance (
    id uuid primary key default gen_random_uuid(),
    student_id uuid not null references public.students(id) on delete cascade,
    attended_on date not null default current_date,
    status text not null check (status in ('present', 'absent', 'late', 'excused')),
    notes text not null default '',
    recorded_by uuid references public.profiles(id) on delete set null,
    created_at timestamptz not null default now(),
    unique (student_id, attended_on)
);

create table if not exists public.grades (
    id uuid primary key default gen_random_uuid(),
    student_id uuid not null references public.students(id) on delete cascade,
    subject text not null,
    assessment text not null,
    score numeric(6, 2) not null check (score >= 0),
    max_score numeric(6, 2) not null check (max_score > 0 and score <= max_score),
    graded_on date not null default current_date,
    recorded_by uuid references public.profiles(id) on delete set null,
    created_at timestamptz not null default now()
);

create table if not exists public.fee_records (
    id uuid primary key default gen_random_uuid(),
    student_id uuid not null references public.students(id) on delete cascade,
    academic_year text not null,
    term text not null default 'Term 1',
    amount_due numeric(12, 2) not null check (amount_due >= 0),
    amount_paid numeric(12, 2) not null default 0 check (amount_paid >= 0 and amount_paid <= amount_due),
    due_date date,
    notes text not null default '',
    updated_by uuid references public.profiles(id) on delete set null,
    updated_at timestamptz not null default now(),
    unique (student_id, academic_year, term)
);

create table if not exists public.timetable (
    id uuid primary key default gen_random_uuid(),
    class_name text not null,
    weekday smallint not null check (weekday between 1 and 7),
    starts_at time not null,
    ends_at time not null check (ends_at > starts_at),
    subject text not null,
    room text not null default '',
    teacher_id uuid references public.profiles(id) on delete set null,
    created_at timestamptz not null default now()
);

create index if not exists students_class_name_idx on public.students(class_name);
create index if not exists attendance_student_date_idx on public.attendance(student_id, attended_on desc);
create index if not exists grades_student_date_idx on public.grades(student_id, graded_on desc);
create index if not exists fee_records_student_year_idx on public.fee_records(student_id, academic_year, term);
create index if not exists timetable_class_weekday_idx on public.timetable(class_name, weekday, starts_at);

create or replace function public.handle_new_school_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (id, email, full_name, role)
    values (
        new.id,
        new.email,
        coalesce(
            nullif(new.raw_user_meta_data ->> 'full_name', ''),
            nullif(new.raw_user_meta_data ->> 'name', ''),
            split_part(coalesce(new.email, ''), '@', 1)
        ),
        'parent'
    )
    on conflict (id) do update
        set email = excluded.email,
            full_name = excluded.full_name;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created_school_profile on auth.users;
create trigger on_auth_user_created_school_profile
after insert or update on auth.users
for each row execute function public.handle_new_school_profile();

create or replace function public.current_school_role()
returns public.school_role
language sql
stable
security definer
set search_path = ''
as $$
    select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_school_leader()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(public.current_school_role() in ('headteacher', 'deputy_headteacher'), false)
$$;

create or replace function public.is_headteacher()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(public.current_school_role() = 'headteacher', false)
$$;

create or replace function public.has_class_assignment(target_class text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.current_school_role() = 'staff'
        and exists (
        select 1
        from public.staff_classes
        where staff_id = auth.uid()
          and class_name = target_class
    )
$$;

create or replace function public.is_parent_of_student(target_student uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.current_school_role() = 'parent'
        and exists (
        select 1
        from public.parent_students
        where parent_id = auth.uid()
          and student_id = target_student
    )
$$;

create or replace function public.can_access_student(target_student uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.is_school_leader()
        or public.is_parent_of_student(target_student)
        or (
            public.current_school_role() = 'staff'
            and exists (
                select 1
                from public.students s
                join public.staff_classes sc on sc.class_name = s.class_name
                where s.id = target_student
                  and sc.staff_id = auth.uid()
            )
        )
$$;

create or replace function public.can_manage_student_records(target_student uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.is_school_leader()
        or (
            public.current_school_role() = 'staff'
            and exists (
                select 1
                from public.students s
                join public.staff_classes sc on sc.class_name = s.class_name
                where s.id = target_student
                  and sc.staff_id = auth.uid()
            )
        )
$$;

create or replace function public.can_view_class(target_class text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.is_school_leader()
        or (
            public.current_school_role() = 'staff'
            and public.has_class_assignment(target_class)
        )
        or (
            public.current_school_role() = 'parent'
            and exists (
            select 1
            from public.students s
            join public.parent_students ps on ps.student_id = s.id
            where s.class_name = target_class
              and ps.parent_id = auth.uid()
            )
        )
$$;

create or replace function public.set_profile_role(target_user uuid, next_role public.school_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not public.is_headteacher() then
        raise exception 'Only the headteacher can change account roles';
    end if;

    if target_user = auth.uid() and next_role <> 'headteacher' then
        raise exception 'The headteacher cannot remove their own role';
    end if;

    update public.profiles
    set role = next_role
    where id = target_user;

    if not found then
        raise exception 'Profile not found';
    end if;
end;
$$;

revoke all on function public.current_school_role() from public, anon;
revoke all on function public.is_school_leader() from public, anon;
revoke all on function public.is_headteacher() from public, anon;
revoke all on function public.has_class_assignment(text) from public, anon;
revoke all on function public.is_parent_of_student(uuid) from public, anon;
revoke all on function public.can_access_student(uuid) from public, anon;
revoke all on function public.can_manage_student_records(uuid) from public, anon;
revoke all on function public.can_view_class(text) from public, anon;
revoke all on function public.set_profile_role(uuid, public.school_role) from public, anon;
grant usage on schema public to authenticated;
grant usage on type public.school_role to authenticated;
grant execute on function public.current_school_role() to authenticated;
grant execute on function public.is_school_leader() to authenticated;
grant execute on function public.is_headteacher() to authenticated;
grant execute on function public.has_class_assignment(text) to authenticated;
grant execute on function public.is_parent_of_student(uuid) to authenticated;
grant execute on function public.can_access_student(uuid) to authenticated;
grant execute on function public.can_manage_student_records(uuid) to authenticated;
grant execute on function public.can_view_class(text) to authenticated;
grant execute on function public.set_profile_role(uuid, public.school_role) to authenticated;

alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.parent_students enable row level security;
alter table public.staff_classes enable row level security;
alter table public.attendance enable row level security;
alter table public.grades enable row level security;
alter table public.fee_records enable row level security;
alter table public.timetable enable row level security;

drop policy if exists profiles_read_self_or_leaders on public.profiles;
create policy profiles_read_self_or_leaders on public.profiles
for select to authenticated
using (id = auth.uid() or public.is_school_leader());

drop policy if exists students_read_authorized on public.students;
create policy students_read_authorized on public.students
for select to authenticated
using (public.can_access_student(id));

drop policy if exists students_leaders_insert on public.students;
create policy students_leaders_insert on public.students
for insert to authenticated
with check (public.is_school_leader());

drop policy if exists students_leaders_update on public.students;
create policy students_leaders_update on public.students
for update to authenticated
using (public.is_school_leader())
with check (public.is_school_leader());

drop policy if exists students_leaders_delete on public.students;
create policy students_leaders_delete on public.students
for delete to authenticated
using (public.is_school_leader());

drop policy if exists parent_students_read_authorized on public.parent_students;
create policy parent_students_read_authorized on public.parent_students
for select to authenticated
using (parent_id = auth.uid() or public.is_school_leader());

drop policy if exists parent_students_leaders_insert on public.parent_students;
create policy parent_students_leaders_insert on public.parent_students
for insert to authenticated
with check (public.is_school_leader());

drop policy if exists parent_students_leaders_delete on public.parent_students;
create policy parent_students_leaders_delete on public.parent_students
for delete to authenticated
using (public.is_school_leader());

drop policy if exists staff_classes_read_authorized on public.staff_classes;
create policy staff_classes_read_authorized on public.staff_classes
for select to authenticated
using ((staff_id = auth.uid() and public.current_school_role() = 'staff') or public.is_school_leader());

drop policy if exists staff_classes_leaders_insert on public.staff_classes;
create policy staff_classes_leaders_insert on public.staff_classes
for insert to authenticated
with check (public.is_school_leader());

drop policy if exists staff_classes_leaders_update on public.staff_classes;
create policy staff_classes_leaders_update on public.staff_classes
for update to authenticated
using (public.is_school_leader())
with check (public.is_school_leader());

drop policy if exists staff_classes_leaders_delete on public.staff_classes;
create policy staff_classes_leaders_delete on public.staff_classes
for delete to authenticated
using (public.is_school_leader());

drop policy if exists attendance_read_authorized on public.attendance;
create policy attendance_read_authorized on public.attendance
for select to authenticated
using (public.can_access_student(student_id));

drop policy if exists attendance_record_authorized on public.attendance;
create policy attendance_record_authorized on public.attendance
for insert to authenticated
with check (public.can_manage_student_records(student_id) and recorded_by = auth.uid());

drop policy if exists attendance_update_authorized on public.attendance;
create policy attendance_update_authorized on public.attendance
for update to authenticated
using (public.can_manage_student_records(student_id))
with check (public.can_manage_student_records(student_id) and recorded_by = auth.uid());

drop policy if exists attendance_leaders_delete on public.attendance;
create policy attendance_leaders_delete on public.attendance
for delete to authenticated
using (public.is_school_leader());

drop policy if exists grades_read_authorized on public.grades;
create policy grades_read_authorized on public.grades
for select to authenticated
using (public.can_access_student(student_id));

drop policy if exists grades_record_authorized on public.grades;
create policy grades_record_authorized on public.grades
for insert to authenticated
with check (public.can_manage_student_records(student_id) and recorded_by = auth.uid());

drop policy if exists grades_update_authorized on public.grades;
create policy grades_update_authorized on public.grades
for update to authenticated
using (public.can_manage_student_records(student_id))
with check (public.can_manage_student_records(student_id) and recorded_by = auth.uid());

drop policy if exists grades_leaders_delete on public.grades;
create policy grades_leaders_delete on public.grades
for delete to authenticated
using (public.is_school_leader());

drop policy if exists fee_records_read_authorized on public.fee_records;
create policy fee_records_read_authorized on public.fee_records
for select to authenticated
using (public.is_school_leader() or public.is_parent_of_student(student_id));

drop policy if exists fee_records_leaders_insert on public.fee_records;
create policy fee_records_leaders_insert on public.fee_records
for insert to authenticated
with check (public.is_school_leader() and updated_by = auth.uid());

drop policy if exists fee_records_leaders_update on public.fee_records;
create policy fee_records_leaders_update on public.fee_records
for update to authenticated
using (public.is_school_leader())
with check (public.is_school_leader() and updated_by = auth.uid());

drop policy if exists fee_records_leaders_delete on public.fee_records;
create policy fee_records_leaders_delete on public.fee_records
for delete to authenticated
using (public.is_school_leader());

drop policy if exists timetable_read_authorized on public.timetable;
create policy timetable_read_authorized on public.timetable
for select to authenticated
using (public.can_view_class(class_name));

drop policy if exists timetable_leaders_insert on public.timetable;
create policy timetable_leaders_insert on public.timetable
for insert to authenticated
with check (public.is_school_leader());

drop policy if exists timetable_leaders_update on public.timetable;
create policy timetable_leaders_update on public.timetable
for update to authenticated
using (public.is_school_leader())
with check (public.is_school_leader());

drop policy if exists timetable_leaders_delete on public.timetable;
create policy timetable_leaders_delete on public.timetable
for delete to authenticated
using (public.is_school_leader());

grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.students to authenticated;
grant select, insert, delete on public.parent_students to authenticated;
grant select, insert, update, delete on public.staff_classes to authenticated;
grant select, insert, update, delete on public.attendance to authenticated;
grant select, insert, update, delete on public.grades to authenticated;
grant select, insert, update, delete on public.fee_records to authenticated;
grant select, insert, update, delete on public.timetable to authenticated;

-- After creating the first trusted account, run this once in the Supabase SQL editor:
-- update public.profiles
-- set role = 'headteacher'
-- where email = 'the-headteacher-email@example.com';
