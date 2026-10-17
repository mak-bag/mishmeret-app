-- ═══════════════════════════════════════════════════════════════════════════════
-- Mishmeret · SERVER SUITE · owner: Tech Lead · v4 · 10/10/2026 (T18–19 M3 card · T20–23 M4a delete/export · T24–27 M4b+c)
-- Run as one statement (SQL Editor / execute_sql). It ALWAYS rolls back: the last line RAISEs,
-- which aborts the transaction. Every probe impersonates (set local role + jwt.claims) — trap 1.
-- Output: one JSON with PASS/FAIL per test and a summary. FAIL anywhere = do not ship.
-- Test data is planted inside the transaction and vanishes with it. Fixtures by role, not by name:
--   OWNER = owner of a business with a shift · WORKER = an adult outside that business ·
--   STRANGER = a user with no business, no application · MINOR = a contact with a birth date < 18y.
-- Adding a test: one block, one name, an expected value written next to it. Prove it fails on the
-- broken code before trusting it (trap 6).
-- ═══════════════════════════════════════════════════════════════════════════════
DO $suite$
DECLARE
  R jsonb := '{}'; pass int := 0; fail int := 0;
  OWNER uuid; BIZ uuid; SH uuid; WORKER uuid; STRANGER uuid; MINOR uuid; OTHERBIZ uuid; OTHERSH uuid;
  v text; n int;
  n2 int;
BEGIN
  -- ── fixtures ────────────────────────────────────────────────────────────────
  select m.user_id, m.business_id into OWNER, BIZ
    from business_members m join businesses b on b.id = m.business_id
   where m.role = 'owner' and b.closed_at is null
     and exists (select 1 from shifts s where s.business_id = b.id) limit 1;
  select id into SH from shifts where business_id = BIZ order by created_at desc limit 1;
  select p.id into WORKER from profiles p join profile_contacts c on c.id = p.id
   where private.is_adult(p.id) and p.home_city_id is not null
     and not exists (select 1 from business_members m where m.user_id = p.id) limit 1;
  select p.id into STRANGER from profiles p
   where not exists (select 1 from business_members m where m.user_id = p.id)
     and not exists (select 1 from applications a where a.worker_id = p.id)
     and p.id <> WORKER limit 1;
  select id into MINOR from profile_contacts where birth_date > current_date - interval '18 years' limit 1;
  select b.id into OTHERBIZ from businesses b where b.id <> BIZ and b.closed_at is null
     and exists (select 1 from shifts s where s.business_id = b.id) limit 1;
  select id into OTHERSH from shifts where business_id = OTHERBIZ limit 1;

  -- make the shift live and open, and the worker terms-current (planted, rolled back)
  update shifts set starts_at = now() + interval '2 hours', ends_at = now() + interval '6 hours',
                    cancelled_at = null, filled = 0, slots = greatest(slots,1) where id = SH;
  update profiles set terms_version = private.terms_version() where id in (WORKER, STRANGER);
  -- the worker lives in the business's city, so T08 compares a real count, never 0 = 0
  update profiles set home_city_id = (select city_id from businesses where id = BIZ) where id = WORKER;
  -- M3: a known birth date, so T19 compares a real age (25), never null = null
  update profile_contacts set birth_date = current_date - interval '25 years' where id = WORKER;
  delete from applications where shift_id = SH and worker_id in (WORKER, STRANGER);

  R := R || jsonb_build_object('_fixtures', jsonb_build_object(
    'owner', left(OWNER::text,8), 'biz', left(BIZ::text,8), 'shift', left(SH::text,8),
    'worker', left(WORKER::text,8), 'stranger', left(STRANGER::text,8), 'minor', left(coalesce(MINOR::text,'-'),8)));

  -- helper pattern: impersonate → probe → reset → compare
  -- ── T01 privilege floor: anon executes 0 functions ───────────────────────────
  select count(*) into n from pg_proc p where p.pronamespace in ('public'::regnamespace,'private'::regnamespace)
     and has_function_privilege('anon',p.oid,'execute') and p.prokind='f';
  R := R || jsonb_build_object('T01_anon_fns_0', case when n=0 then 'PASS' else 'FAIL got '||n end);

  -- ── T02 a NEW function is anon=false, authenticated=true (default privileges, trap 2) ──
  create function public._suite_probe() returns int language sql as 'select 1';
  v := has_function_privilege('anon','public._suite_probe()','execute')::text||','||has_function_privilege('authenticated','public._suite_probe()','execute')::text;
  R := R || jsonb_build_object('T02_new_fn_defaults', case when v='false,true' then 'PASS' else 'FAIL got '||v end);

  -- ── T03 stranger reads only their own profile ────────────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub',STRANGER,'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated; select count(*) into n from profiles; RESET ROLE;
  R := R || jsonb_build_object('T03_stranger_profiles_1', case when n=1 then 'PASS' else 'FAIL got '||n end);

  -- ── T04 stranger cannot read a business phone (column privilege) ─────────────
  BEGIN
    SET LOCAL ROLE authenticated; select count(phone) into n from businesses; RESET ROLE; v := 'readable '||n;
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; v := '42501'; END;
  R := R || jsonb_build_object('T04_biz_phone_42501', case when v='42501' then 'PASS' else 'FAIL '||v end);

  -- ── T05 board columns stay readable ──────────────────────────────────────────
  SET LOCAL ROLE authenticated; select count(*) into n from (select id,name,address,city,lat,lng,verified_at from businesses) x; RESET ROLE;
  R := R || jsonb_build_object('T05_board_columns', case when n>0 then 'PASS' else 'FAIL got 0' end);

  -- ── T06 shift_counts exposes exactly (city_id, radius_km, n) to anon ─────────
  select string_agg(column_name, ',' order by ordinal_position) into v from information_schema.columns where table_schema='public' and table_name='shift_counts';
  R := R || jsonb_build_object('T06_counts_columns', case when v='city_id,radius_km,n' then 'PASS' else 'FAIL got '||coalesce(v,'none') end);
  PERFORM set_config('request.jwt.claims','{"role":"anon"}', true);
  SET LOCAL ROLE anon; select count(*) into n from shift_counts; RESET ROLE;
  R := R || jsonb_build_object('T07_counts_anon_reads', case when n>0 then 'PASS' else 'FAIL got 0' end);

  -- ── T08 count == board for the worker's city and radius ──────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub',WORKER,'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated; select count(*) into n from shifts_for_me(20); RESET ROLE;
  select sc.n into n2 from shift_counts sc join profiles p on p.home_city_id = sc.city_id
   where p.id = WORKER and sc.radius_km = 20;
  R := R || jsonb_build_object('T08_count_eq_board', case when n = n2 and n > 0 then 'PASS ('||n||')' else 'FAIL board '||n||' view '||coalesce(n2,-1)||' (must be equal and > 0)' end);

  -- ── T09 full shift refuses details (S5) ──────────────────────────────────────
  update shifts set filled = slots where id = SH;
  SET LOCAL ROLE authenticated; select send_details(SH,'today',null)->>'result' into v; RESET ROLE;
  R := R || jsonb_build_object('T09_full_refuses', case when v='full' then 'PASS' else 'FAIL got '||v end);
  select count(*) into n from applications where shift_id=SH and worker_id=WORKER;
  R := R || jsonb_build_object('T10_full_writes_nothing', case when n=0 then 'PASS' else 'FAIL rows '||n end);
  update shifts set filled = 0 where id = SH;

  -- ── T11 open shift accepts details ───────────────────────────────────────────
  SET LOCAL ROLE authenticated; select send_details(SH,'today',null)->>'result' into v; RESET ROLE;
  R := R || jsonb_build_object('T11_open_sends', case when v='details_sent' then 'PASS' else 'FAIL got '||v end);

  -- ── T12 owner sees the phone only after details were sent; stranger's profile not visible ─
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER,'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated; select count(*) into n from shift_applicants(SH) x where x.worker_id=WORKER and x.phone is not null; RESET ROLE;
  R := R || jsonb_build_object('T12_owner_sees_phone_after_send', case when n=1 then 'PASS' else 'FAIL got '||n end);

  -- ── T13 "did not show up" never crosses businesses (P2) ──────────────────────
  if OTHERSH is not null then
    insert into reviews(shift_id, worker_id, business_id, direction, author_id, attended, disputed)
    values (OTHERSH, WORKER, OTHERBIZ, 'business_to_worker',
            (select user_id from business_members where business_id=OTHERBIZ limit 1), 'no', false);
    SET LOCAL ROLE authenticated; select x.attended_no into n from shift_applicants(SH) x where x.worker_id=WORKER; RESET ROLE;
    R := R || jsonb_build_object('T13_noshow_local', case when n=0 then 'PASS' else 'FAIL got '||n end);
  else
    R := R || jsonb_build_object('T13_noshow_local', 'SKIP no second business');
  end if;

  -- ── T14 offer → exactly one notification, also on re-offer ───────────────────
  -- The worker APPLIED first (T11), so the offer updates an initiated_by='worker' row — the case
  -- that failed on 06/10 before v1_offer_notification_any_origin.
  SET LOCAL ROLE authenticated; select offer_shift(SH, WORKER) into v; RESET ROLE;
  update applications set status='applied' where shift_id=SH and worker_id=WORKER;
  SET LOCAL ROLE authenticated; perform offer_shift(SH, WORKER); RESET ROLE;
  select count(*) into n from notifications where kind='offered' and shift_id=SH and user_id=WORKER;
  R := R || jsonb_build_object('T14_offer_notifies_once', case when v='offered' and n=1 then 'PASS' else 'FAIL '||v||' n='||n end);

  -- ── M3 (07/10) · business card. Dynamic SQL so the suite runs (and FAILs) before the new columns exist ──
  -- T18: the owner cannot read the worker's phone straight from the table, even with the offer open (T14).
  --      Before M3 the contacts_read policy returned it, with no time bound.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER,'role','authenticated')::text, true);
  SET LOCAL ROLE authenticated; select count(phone) into n from profile_contacts where id = WORKER; RESET ROLE;
  R := R || jsonb_build_object('T18_contacts_self_only', case when n=0 then 'PASS' else 'FAIL owner reads '||n end);
  -- T19: the card the owner gets = age (planted birth date: exactly 25) + distance from the city centre (km)
  BEGIN
    SET LOCAL ROLE authenticated;
    execute format('select x.age, x.distance_km from shift_applicants(%L) x where x.worker_id=%L', SH, WORKER) into n, n2;
    RESET ROLE;
    R := R || jsonb_build_object('T19_card_age_distance', case when n=25 and n2 between 0 and 60
         then 'PASS (25y, '||n2||'km)' else 'FAIL age '||coalesce(n::text,'null')||' km '||coalesce(n2::text,'null') end);
  EXCEPTION WHEN undefined_column THEN RESET ROLE;
    R := R || jsonb_build_object('T19_card_age_distance', 'FAIL no age/distance_km columns');
  END;

  -- ── M4b+c (10/10) · phone 30 days · team = the worker's choice · retention sweep ──
  if to_regprocedure('public.respond_team(uuid,boolean)') is null then
    R := R || jsonb_build_object('T24_phone_gone_after_30d','FAIL no M4b','T25_invite_not_team','FAIL no M4c',
                                 'T26_accepted_team_keeps_phone','FAIL no M4c','T27_retention_sweep','FAIL no M4b');
  else
    -- T24: the shift ended 40 days ago, the worker is not in the team ⇒ the owner no longer gets the phone
    update shifts set starts_at = now() - interval '40 days 4 hours', ends_at = now() - interval '40 days' where id = SH;
    PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated; select count(*) into n from shift_applicants(SH) x where x.worker_id=WORKER and x.phone is null;
                                  select count(*) into n2 from shift_applicants(SH) x where x.worker_id=WORKER; RESET ROLE;
    R := R || jsonb_build_object('T24_phone_gone_after_30d', case when n=1 and n2=1 then 'PASS' else 'FAIL null-phone '||n||' of '||n2 end);
    -- T25: a business row is an invite: one team_invite notification, and NOT a team member yet
    delete from team_members where business_id = BIZ and worker_id = WORKER;
    insert into team_members(business_id, worker_id, added_by) values (BIZ, WORKER, OWNER);
    select count(*) into n from notifications where user_id = WORKER and business_id = BIZ and kind = 'team_invite';
    v := private.is_team(BIZ, WORKER)::text;
    R := R || jsonb_build_object('T25_invite_not_team', case when n=1 and v='false' then 'PASS' else 'FAIL notif '||n||' is_team '||v end);
    -- T26: the worker accepts ⇒ team ⇒ the owner gets the phone again, past 30 days
    PERFORM set_config('request.jwt.claims', json_build_object('sub',WORKER,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated; select respond_team(BIZ, true)->>'result' into v; RESET ROLE;
    PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated; select count(*) into n from shift_applicants(SH) x where x.worker_id=WORKER and x.phone is not null and x.is_regular; RESET ROLE;
    R := R || jsonb_build_object('T26_accepted_team_keeps_phone', case when v='accepted' and n=1 then 'PASS' else 'FAIL '||v||' n='||n end);
    -- T27: a 61-day-old notification. DRY (the cron default since M4d) counts it and deletes nothing;
    --      LIVE deletes it and keeps integrity (filled == confirmed).
    insert into notifications(user_id, kind, business_id, created_at) values (WORKER, 'new_shift', BIZ, now() - interval '61 days');
    if to_regprocedure('private.retention_sweep(boolean)') is null then
      R := R || jsonb_build_object('T27_retention_dry_then_live', 'FAIL no retention_sweep(boolean) — M4d');
    else
      select (private.retention_sweep(false)->>'notifications')::int into n2;
      select count(*) into n from notifications where created_at < now() - interval '60 days';
      v := n2||'/'||n;
      perform private.retention_sweep(true);
      select (select count(*) from notifications where created_at < now() - interval '60 days')
           + (select count(*) from shifts s where s.filled <> (select count(*) from applications a where a.shift_id=s.id and a.status='confirmed'))
        into n;
      R := R || jsonb_build_object('T27_retention_dry_then_live', case when n2 >= 1 and v = n2||'/'||n2 and n = 0
           then 'PASS (dry counted '||n2||', live left 0)' else 'FAIL dry '||v||' live left '||n end);
    end if;
  end if;

  -- ── T15 adult attestation: a click works for no-birth-date, never overrides a minor ──
  if MINOR is not null then
    PERFORM set_config('request.jwt.claims', json_build_object('sub',MINOR,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated; select confirm_adult()->>'result' into v; RESET ROLE;
    R := R || jsonb_build_object('T15_minor_not_overridden', case when v='minors_soon' then 'PASS' else 'FAIL got '||v end);
  else
    R := R || jsonb_build_object('T15_minor_not_overridden', 'SKIP no minor');
  end if;

  -- ── T16 claim_shift is retired ───────────────────────────────────────────────
  R := R || jsonb_build_object('T16_claim_retired',
     case when not has_function_privilege('authenticated','public.claim_shift(uuid)','execute') then 'PASS' else 'FAIL executable' end);

  -- ── T17 integrity (Q5 core): no orphans, filled == confirmed ─────────────────
  select (select count(*) from applications a left join shifts s on s.id=a.shift_id where s.id is null)
       + (select count(*) from businesses b where not exists (select 1 from business_members m where m.business_id=b.id and m.role='owner'))
       + (select count(*) from profiles p left join profile_contacts c on c.id=p.id where c.id is null)
       + (select count(*) from shifts s where s.filled <> (select count(*) from applications a where a.shift_id=s.id and a.status='confirmed'))
    into n;
  R := R || jsonb_build_object('T17_integrity', case when n=0 then 'PASS' else 'FAIL '||n end);

  -- ── M4a (10/10) · delete + export. LAST: they delete people (rolled back with everything else) ──
  if to_regprocedure('public.delete_my_account()') is null then
    R := R || jsonb_build_object('T20_export_mine','FAIL no export_my_data','T21_owner_open_refused','FAIL no delete_my_account',
                                 'T22_worker_deleted_clean','FAIL no delete_my_account','T23_creator_deleted_clean','FAIL no delete_my_account');
  else
    -- T20: the worker's export holds their phone and the application from T11
    PERFORM set_config('request.jwt.claims', json_build_object('sub',WORKER,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated; execute 'select export_my_data()' into v; RESET ROLE;
    R := R || jsonb_build_object('T20_export_mine', case when (v::jsonb->'contact'->>'phone') is not null
         and jsonb_array_length(v::jsonb->'applications') >= 1 then 'PASS ('||jsonb_array_length(v::jsonb->'applications')||' apps)'
         else 'FAIL '||left(coalesce(v,'null'),120) end);
    -- T21: sole owner of an open business is refused, nothing deleted
    PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated; execute 'select delete_my_account()->>''result''' into v; RESET ROLE;
    select count(*) into n from auth.users where id = OWNER;
    R := R || jsonb_build_object('T21_owner_open_refused', case when v='close_business_first' and n=1 then 'PASS' else 'FAIL '||v||' users='||n end);
    -- T22: the worker deletes; no row in public carries their id; integrity holds (filled == confirmed)
    PERFORM set_config('request.jwt.claims', json_build_object('sub',WORKER,'role','authenticated')::text, true);
    SET LOCAL ROLE authenticated; execute 'select delete_my_account()->>''result''' into v; RESET ROLE;
    select (select count(*) from auth.users where id=WORKER) + (select count(*) from profiles where id=WORKER)
         + (select count(*) from profile_contacts where id=WORKER) + (select count(*) from applications where worker_id=WORKER)
         + (select count(*) from reviews where worker_id=WORKER) + (select count(*) from notifications where user_id=WORKER)
         + (select count(*) from team_members where worker_id=WORKER) + (select count(*) from saved_shifts where worker_id=WORKER)
         + (select count(*) from private_notes where worker_id=WORKER)
         + (select count(*) from shifts s where s.filled <> (select count(*) from applications a where a.shift_id=s.id and a.status='confirmed'))
      into n;
    R := R || jsonb_build_object('T22_worker_deleted_clean', case when v='deleted' and n=0 then 'PASS' else 'FAIL '||v||' left='||n end);
    -- T23: the owner who CREATED shifts deletes after closing their businesses (the NO ACTION FKs failed this)
    update businesses set closed_at = now() where closed_at is null
       and id in (select business_id from business_members where user_id = OWNER and role = 'owner');
    PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER,'role','authenticated')::text, true);
    BEGIN
      SET LOCAL ROLE authenticated; execute 'select delete_my_account()->>''result''' into v; RESET ROLE;
    EXCEPTION WHEN others THEN RESET ROLE; v := 'ERR '||SQLSTATE||' '||left(SQLERRM,60); END;
    select (select count(*) from auth.users where id=OWNER) + (select count(*) from businesses where id=BIZ)
         + (select count(*) from businesses b where not exists (select 1 from business_members m where m.business_id=b.id and m.role='owner'))
      into n;
    R := R || jsonb_build_object('T23_creator_deleted_clean', case when v='deleted' and n=0 then 'PASS' else 'FAIL '||v||' left='||n end);
  end if;

  -- ── summary ──────────────────────────────────────────────────────────────────
  select count(*) filter (where value #>> '{}' like 'PASS%'), count(*) filter (where value #>> '{}' like 'FAIL%')
    into pass, fail from jsonb_each(R) where key like 'T%';
  R := R || jsonb_build_object('_summary', pass||' PASS · '||fail||' FAIL');
  RAISE EXCEPTION 'SUITE %', jsonb_pretty(R);   -- rolls everything back
END $suite$;
