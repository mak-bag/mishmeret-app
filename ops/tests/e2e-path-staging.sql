-- e2e-path-staging.sql · Tech Lead · 12/10/2026 · STAGING ONLY (sjwkfhqsqpxknlfncbbq). Never production (H9).
-- The full v1.0 path with three fresh dummy users, every call made AS that user (role authenticated + jwt sub),
-- with the EXACT arguments app.html (RC3) sends. Signup = an auth.users row with the client's signUp metadata,
-- so handle_new_user runs as in real life. Everything is rolled back by the final RAISE: nothing remains.
-- Output: the RAISE message = one JSON, step → value. Read it, don't trust a green word.
do $$
declare
  W uuid := gen_random_uuid();  M uuid := gen_random_uuid();  B uuid := gen_random_uuid();
  BIZ uuid; SH uuid; SH2 uuid; r jsonb; t text; n int; n2 int;
  REP jsonb := '{}';
  CITY int := 22;  -- tel-aviv (32.0853,34.7818)
  START timestamptz := date_trunc('day', now()) + interval '1 day 18 hours';
begin
  -- ---------- signup (what sb.auth.signUp + handle_new_user do) ----------
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
   ('00000000-0000-0000-0000-000000000000', W, 'authenticated','authenticated','972500000901@mak-bag.com','', now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name','דנה בדיקה','phone','+972500000901','home_city_id',CITY,'lang','he','country_code','IL'), now(), now()),
   ('00000000-0000-0000-0000-000000000000', M, 'authenticated','authenticated','972500000902@mak-bag.com','', now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name','נוער בדיקה','phone','+972500000902','home_city_id',CITY,'lang','he','country_code','IL'), now(), now()),
   ('00000000-0000-0000-0000-000000000000', B, 'authenticated','authenticated','972500000903@mak-bag.com','', now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name','יוסי בעלים','phone','+972500000903','home_city_id',CITY,'lang','he','country_code','IL'), now(), now());
  select count(*) into n from public.profiles where id in (W, M, B);
  REP := REP || jsonb_build_object('S01_signup_profiles_3', n);

  -- ---------- worker joins (joinFinish, seeker) ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',W,'role','authenticated')::text, true);
    set local role authenticated;
    r := accept_terms('2026-09-26');                                   REP := REP || jsonb_build_object('S02_w_accept_terms', r);
    r := complete_worker_profile(p_given => 'דנה', p_family => 'בדיקה', p_city_id => CITY, p_birth_date => (current_date - interval '25 years')::date, p_radius_km => 20);
                                                                       REP := REP || jsonb_build_object('S03_w_complete_profile', r);
    r := set_preferences(p_categories => '{food}', p_hours => '{evening,noon}', p_travel_mode => null, p_max_travel_min => null);
                                                                       REP := REP || jsonb_build_object('S04_w_preferences', r);
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S02_04_worker_join_ERROR', sqlerrm); end;
  select jsonb_build_object('full_name', p.full_name, 'given', p.given_name, 'family', p.family_name, 'city', p.home_city_id)
    into r from public.profiles p where p.id = W;                      REP := REP || jsonb_build_object('S05_w_profile_row', r);

  -- ---------- minor joins ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',M,'role','authenticated')::text, true);
    set local role authenticated;
    r := accept_terms('2026-09-26');
    r := complete_worker_profile(p_given => 'נוער', p_family => 'בדיקה', p_city_id => CITY, p_birth_date => (current_date - interval '16 years')::date, p_radius_km => 20);
                                                                       REP := REP || jsonb_build_object('S06_minor_complete_profile', r);
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S06_minor_ERROR', sqlerrm); end;

  -- ---------- business joins (joinFinish, business) + posts (newShift form) ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',B,'role','authenticated')::text, true);
    set local role authenticated;
    r := accept_terms('2026-09-26');
    r := create_business(p_name => 'קפה בדיקה', p_city_id => CITY, p_address => '', p_phone => '+972500000903', p_kind => 'restaurant', p_lat => 32.0800, p_lng => 34.7800);
    BIZ := (r->>'id')::uuid;                                           REP := REP || jsonb_build_object('S07_b_create_business', r);
    r := post_shift(p_business => BIZ, p_role_code => 'waiter', p_role_label => '', p_starts => START, p_ends => START + interval '6 hours',
                    p_rate => 50, p_slots => 1, p_instant => false, p_urgent => false, p_transport => false, p_descr => 'משמרת ערב',
                    p_max_distance_km => null, p_adults_only => false);
    SH := coalesce((r->>'id')::uuid, (r->>'shift_id')::uuid);         REP := REP || jsonb_build_object('S08_b_post_shift', r);
    r := post_shift(p_business => BIZ, p_role_code => 'bartender', p_role_label => '', p_starts => START, p_ends => START + interval '6 hours',
                    p_rate => 60, p_slots => 1, p_instant => false, p_urgent => false, p_transport => false, p_descr => '',
                    p_max_distance_km => null, p_adults_only => true);
    SH2 := coalesce((r->>'id')::uuid, (r->>'shift_id')::uuid);        REP := REP || jsonb_build_object('S09_b_post_bartender_18', r);
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S07_09_business_ERROR', sqlerrm); end;

  -- ---------- an anonymous visitor (landing count) ----------
  begin
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
    select coalesce(max(sc.n),0) into n from shift_counts sc where sc.city_id = CITY and sc.radius_km = 20;
    reset role;                                                         REP := REP || jsonb_build_object('S10_anon_count_tlv_20', n);
  exception when others then reset role; REP := REP || jsonb_build_object('S10_anon_ERROR', sqlerrm); end;

  -- ---------- worker finds and sends details ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',W,'role','authenticated')::text, true);
    set local role authenticated;
    select count(*) into n from shifts_for_me(20) s where s.id in (SH, SH2);   REP := REP || jsonb_build_object('S11_w_board_sees_2', n);
    r := shift_details(SH);                                            REP := REP || jsonb_build_object('S12_w_shift_details_has_biz', (r ? 'biz_name') or (r->'shift' ? 'biz_name') or r is not null);
    r := send_details(p_shift => SH, p_start_when => 'today', p_experience => 'עבדתי שנתיים כמלצרית');
                                                                       REP := REP || jsonb_build_object('S13_w_send_details', r);
    r := send_details(p_shift => SH, p_start_when => 'today', p_experience => 'עבדתי שנתיים כמלצרית');
                                                                       REP := REP || jsonb_build_object('S14_w_send_details_twice', r);
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S11_14_worker_send_ERROR', sqlerrm); end;

  -- ---------- minor vs an 18+ shift ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',M,'role','authenticated')::text, true);
    set local role authenticated;
    r := send_details(p_shift => SH2, p_start_when => 'today', p_experience => null);
                                                                       REP := REP || jsonb_build_object('S15_minor_send_18plus', r);
    select count(*) into n from shift_applicants(SH);                  REP := REP || jsonb_build_object('S16_minor_reads_others_applicants', n);
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S15_16_minor_ERROR', left(sqlerrm, 120)); end;

  -- ---------- the business card ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',B,'role','authenticated')::text, true);
    set local role authenticated;
    select jsonb_build_object('name', x.full_name, 'age', x.age, 'km', x.distance_km, 'phone', x.phone is not null,
                              'said', x.experience_note, 'status', x.status, 'shared', x.contact_shared)
      into r from shift_applicants(SH) x where x.worker_id = W;        REP := REP || jsonb_build_object('S17_b_card', r);
    perform mark_applicants_opened(SH);
    r := my_notifications(40);                                         REP := REP || jsonb_build_object('S18_b_notifications', (select jsonb_agg(e->>'kind') from jsonb_array_elements(coalesce(r->'items', r)) e));
    t := approve_application(SH, W);                                   REP := REP || jsonb_build_object('S19_b_approve', t);
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S17_19_business_ERROR', sqlerrm); end;

  -- ---------- worker side after approve ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',W,'role','authenticated')::text, true);
    set local role authenticated;
    select app_status into t from my_shifts() where shift_id = SH;     REP := REP || jsonb_build_object('S20_w_status_after_approve', t);
    if t = 'offered' then t := accept_offer(SH); REP := REP || jsonb_build_object('S20b_w_accept_offer', t); end if;
    r := my_notifications(40);                                         REP := REP || jsonb_build_object('S21_w_notifications', (select jsonb_agg(jsonb_build_object('k', e->>'kind', 'biz', e->>'biz_name')) from jsonb_array_elements(coalesce(r->'items', r)) e));
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S20_21_worker_ERROR', sqlerrm); end;

  -- ---------- regular team: invite (client insert) → worker consents ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',B,'role','authenticated')::text, true);
    set local role authenticated;
    insert into team_members (business_id, worker_id, added_by) values (BIZ, W, B);
    reset role;
    perform set_config('request.jwt.claims', json_build_object('sub',W,'role','authenticated')::text, true);
    set local role authenticated;
    r := my_notifications(40);
    REP := REP || jsonb_build_object('S22_w_team_invite_notif', (select count(*) from jsonb_array_elements(coalesce(r->'items', r)) e where e->>'kind' = 'team_invite'));
    select count(*) into n from team_members tm where tm.worker_id = W and tm.accepted_at is null;   -- loadMyTeams reads this
    r := respond_team(BIZ, true);                                      REP := REP || jsonb_build_object('S23_w_respond_team', r, 'S23_pending_seen_by_worker', n);
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S22_23_team_ERROR', sqlerrm); end;

  -- ---------- after the shift: attendance ----------
  begin
    update public.shifts set starts_at = now() - interval '7 hours', ends_at = now() - interval '1 hour' where id = SH;   -- time passes (superuser)
    perform set_config('request.jwt.claims', json_build_object('sub',B,'role','authenticated')::text, true);
    set local role authenticated;
    r := mark_attendance(SH, W, 'yes');                                REP := REP || jsonb_build_object('S24_b_mark_attendance', r);
    r := biz_dashboard(BIZ);                                           REP := REP || jsonb_build_object('S25_b_dashboard_ok', r is not null);
    reset role;
    perform set_config('request.jwt.claims', json_build_object('sub',W,'role','authenticated')::text, true);
    set local role authenticated;
    r := worker_dashboard();                                           REP := REP || jsonb_build_object('S26_w_dashboard_done', r->'shifts_done');
    reset role;
  exception when others then reset role; REP := REP || jsonb_build_object('S24_26_after_ERROR', sqlerrm); end;

  -- ---------- export + delete ----------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub',W,'role','authenticated')::text, true);
    set local role authenticated;
    r := export_my_data();                                             REP := REP || jsonb_build_object('S27_w_export', jsonb_build_object('phone', r->'contact'->>'phone', 'apps', jsonb_array_length(coalesce(r->'applications','[]'))));
    reset role;
    perform set_config('request.jwt.claims', json_build_object('sub',B,'role','authenticated')::text, true);
    set local role authenticated;
    r := delete_my_account();                                          REP := REP || jsonb_build_object('S28_b_delete_while_open', r->>'result');
    reset role;
    perform set_config('request.jwt.claims', json_build_object('sub',W,'role','authenticated')::text, true);
    set local role authenticated;
    r := delete_my_account();                                          REP := REP || jsonb_build_object('S29_w_delete', r->>'result');
    reset role;
    select (select count(*) from auth.users where id = W) + (select count(*) from public.profiles where id = W) into n;
    REP := REP || jsonb_build_object('S30_w_gone_rows', n);
    perform set_config('request.jwt.claims', json_build_object('sub',B,'role','authenticated')::text, true);
    set local role authenticated;
    select count(*) into n from shift_applicants(SH);                  REP := REP || jsonb_build_object('S31_b_applicants_after_w_deleted', n);
    r := close_business(BIZ);                                          REP := REP || jsonb_build_object('S32_b_close_business', r->>'result');
    r := delete_my_account();                                          REP := REP || jsonb_build_object('S33_b_delete_after_close', r->>'result');
    reset role;
    select count(*) into n from auth.users where id = B;               REP := REP || jsonb_build_object('S34_b_gone', n = 0);
  exception when others then reset role; REP := REP || jsonb_build_object('S27_34_delete_ERROR', sqlerrm); end;

  raise exception 'E2E (rolled back) %', REP::text;
end $$;
