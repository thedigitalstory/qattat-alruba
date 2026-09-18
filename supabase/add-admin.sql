-- After creating your admin user in Authentication > Users,
-- replace the UUID below with the user's User UID, then run this query.
-- You can run it again with another UID to appoint a second administrator.
insert into public.qatta_admins (user_id)
values ('REPLACE_WITH_ADMIN_USER_UUID'::uuid)
on conflict (user_id) do nothing;
