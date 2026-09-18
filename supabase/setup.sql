-- قطّة الربع — run once in your Supabase project's SQL Editor.
-- Safe to re-run: it does not replace an existing ledger or administrator.
begin;

create schema if not exists qatta_private;
revoke all on schema qatta_private from public, anon;
grant usage on schema qatta_private to authenticated;

create or replace function qatta_private.valid_text(v jsonb, maximum integer, required boolean default true)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(jsonb_typeof(v) = 'string' and length(v #>> '{}') <= maximum
    and (not required or length(btrim(v #>> '{}')) > 0), false);
$$;

create or replace function qatta_private.valid_amount(v jsonb, allow_zero boolean default false)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  return coalesce(jsonb_typeof(v) = 'number' and (v #>> '{}') ~ '^[0-9]+$'
    and (v #>> '{}')::numeric between (case when allow_zero then 0 else 1 end) and 10000000, false);
exception when others then return false;
end;
$$;

create or replace function qatta_private.valid_date(v jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
declare d text := v #>> '{}';
begin
  return coalesce(jsonb_typeof(v) = 'string' and d ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    and to_char(d::date, 'YYYY-MM-DD') = d, false);
exception when others then return false;
end;
$$;

create or replace function qatta_private.valid_ledger(d jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
declare s jsonb; m jsonb; p jsonb; e jsonb; k text; ids text[]; expense_ids text[];
begin
  if jsonb_typeof(d) is distinct from 'object' or d->'version' is distinct from '1'::jsonb
    or d->'demo' is distinct from 'false'::jsonb or octet_length(d::text) > 2000000
    or jsonb_typeof(d->'settings') is distinct from 'object'
    or jsonb_typeof(d->'months') is distinct from 'object' then return false; end if;
  s := d->'settings';
  if not qatta_private.valid_text(s->'name',80) or not qatta_private.valid_text(s->'recipient',80)
    or not qatta_private.valid_text(s->'transfer',500,false)
    or not qatta_private.valid_amount(s->'dues') then return false; end if;
  if (select count(*) from jsonb_object_keys(d->'months')) > 600 then return false; end if;
  for k,m in select * from jsonb_each(d->'months') loop
    if k !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' or k < '2000-01' or k > '2100-12'
      or jsonb_typeof(m) is distinct from 'object' or not qatta_private.valid_amount(m->'dues')
      or not qatta_private.valid_text(m->'recipient',80) or not qatta_private.valid_text(m->'transfer',500,false)
      or jsonb_typeof(m->'members') is distinct from 'array' or jsonb_typeof(m->'expenses') is distinct from 'array'
      then return false; end if;
    if jsonb_array_length(m->'members') > 200 or jsonb_array_length(m->'expenses') > 500 then return false; end if;
    ids := array[]::text[];
    for p in select * from jsonb_array_elements(m->'members') loop
      if not qatta_private.valid_text(p->'id',100) or not qatta_private.valid_text(p->'name',80)
        or not qatta_private.valid_text(p->'note',300,false) or not qatta_private.valid_amount(p->'paid',true)
        then return false; end if;
      if (p->>'paid')::numeric > (m->>'dues')::numeric or p->>'id' = any(ids) then return false; end if;
      if (p->>'paid')::numeric > 0 then
        if not qatta_private.valid_date(p->'date') or left(p->>'date',7) <> k then return false; end if;
      elsif p->'date' is distinct from '""'::jsonb then return false;
      end if;
      ids := array_append(ids,p->>'id');
    end loop;
    expense_ids := array[]::text[];
    for e in select * from jsonb_array_elements(m->'expenses') loop
      if not qatta_private.valid_text(e->'id',100) or not qatta_private.valid_text(e->'title',80)
        or not qatta_private.valid_amount(e->'amount') or not qatta_private.valid_date(e->'date')
        or jsonb_typeof(e->'paid') is distinct from 'boolean'
        or coalesce(e->>'category','') not in ('rent','bills','supplies','other')
        or e->>'id' = any(expense_ids) then return false; end if;
      expense_ids := array_append(expense_ids,e->>'id');
    end loop;
  end loop;
  return true;
exception when others then return false;
end;
$$;

revoke all on all functions in schema qatta_private from public, anon;
grant execute on all functions in schema qatta_private to authenticated;

create table if not exists public.qatta_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.qatta_admins enable row level security;
revoke all on public.qatta_admins from public, anon, authenticated;
grant select on public.qatta_admins to authenticated;
drop policy if exists qatta_admin_self on public.qatta_admins;
create policy qatta_admin_self on public.qatta_admins for select to authenticated
  using ((select auth.uid()) = user_id);

create table if not exists public.qatta_ledger (
  id text primary key default 'main' check (id = 'main'),
  data jsonb not null check (qatta_private.valid_ledger(data)),
  revision bigint not null default 0 check (revision >= 0)
);
alter table public.qatta_ledger enable row level security;
revoke all on public.qatta_ledger from public, anon, authenticated;
grant select on public.qatta_ledger to anon, authenticated;
grant update (data, revision) on public.qatta_ledger to authenticated;
drop policy if exists qatta_public_read on public.qatta_ledger;
create policy qatta_public_read on public.qatta_ledger for select to anon, authenticated using (true);
drop policy if exists qatta_admin_update on public.qatta_ledger;
create policy qatta_admin_update on public.qatta_ledger for update to authenticated
  using (exists (select 1 from public.qatta_admins where user_id = (select auth.uid())))
  with check (exists (select 1 from public.qatta_admins where user_id = (select auth.uid())));

insert into public.qatta_ledger (id,data) values ('main', '{"version":1,"demo":false,"settings":{"name":"استراحة الربع","recipient":"حمدان (أبو ذنب)","dues":20000,"transfer":""},"months":{}}'::jsonb)
on conflict (id) do nothing;

-- Optimistic concurrency: the second editor must reload rather than overwrite.
create or replace function public.save_qatta(expected_revision bigint,new_data jsonb)
returns setof public.qatta_ledger language plpgsql security invoker set search_path = '' as $$
begin
  if not exists (select 1 from public.qatta_admins where user_id = (select auth.uid())) then
    raise exception 'QATTA_FORBIDDEN' using errcode = '42501';
  end if;
  return query update public.qatta_ledger set data = new_data, revision = revision + 1
    where id = 'main' and revision = expected_revision returning *;
  if not found then raise exception 'QATTA_CONFLICT'; end if;
end;
$$;
revoke all on function public.save_qatta(bigint,jsonb) from public, anon;
grant execute on function public.save_qatta(bigint,jsonb) to authenticated;
commit;
