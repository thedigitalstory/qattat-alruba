-- Optional first-time setup: add the requested roster to the current Saudi month.
-- An existing month is never replaced. No payments or expenses are invented.
with month_seed as (
  select to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM') as month_key,
  jsonb_build_object('dues', 20000, 'recipient', 'حمدان (أبو ذنب)', 'transfer', '',
    'members', (select jsonb_agg(jsonb_build_object('id', 'member-' || ord, 'name', name, 'paid', 0, 'date', '', 'note', '') order by ord)
      from unnest(array['علي (قوقل)','خالد محي','بدر','سالم','أبو هادي (الصومعه)','أحمد (أحمد فيديو)','مجاد','فيصل','فايز','حمدان (أبو ذنب)','فهد','مفوز']) with ordinality as people(name, ord)),
    'expenses', '[]'::jsonb) as month_data
)
update public.qatta_ledger as ledger
set data = jsonb_set(ledger.data, array['months', month_seed.month_key], month_seed.month_data),
    revision = ledger.revision + 1
from month_seed
where ledger.id = 'main' and not (ledger.data->'months' ? month_seed.month_key);

select id, revision, data->'settings'->>'recipient' as manager,
  (data->'settings'->>'dues')::integer / 100 as dues_sar,
  jsonb_array_length(data->'months'->to_char(now() at time zone 'Asia/Riyadh','YYYY-MM')->'members') as members
from public.qatta_ledger where id = 'main';
