-- Quiet hours + daily messages to people who haven't bought a plan
-- (owner approved).
--
-- Quiet hours (default 3:00-9:00 India time): no automatic message goes out.
-- Messages that fall due at night stay "scheduled" and go out at 9:00;
-- before that, held payment / plan messages are dropped if the person paid
-- meanwhile and only the newest held message per person is kept. Messages the
-- owner sends by hand are never held.
--
-- Daily messages ("nonbuyer"): to every phone whose owner never bought a plan
-- (or only ads installs, as the owner picks), at set hours (default 9:00,
-- 14:00, 19:00, 0:00 India time), for N days after install (default 14).
-- Each phone gets the next message in the owner's list; content messages
-- (trending, just added, premium, what they watched, busiest channel) take
-- turns with plan reminders. Skipped when the phone got another automatic
-- message in the last 2 hours.

alter table public.push_settings
  add column if not exists quiet_on boolean not null default true,
  add column if not exists quiet_from int not null default 3 check (quiet_from between 0 and 23),
  add column if not exists quiet_to int not null default 9 check (quiet_to between 0 and 23),
  add column if not exists nb_hours int[] not null default '{9,14,19,0}',
  add column if not exists nb_audience text not null default 'all' check (nb_audience in ('all', 'ads'));

alter table public.push_auto drop constraint if exists push_auto_kind_check;
alter table public.push_auto add constraint push_auto_kind_check
  check (kind in ('payment_reminder', 'payment_approved', 'plan_ending', 'come_back', 'new_videos',
                  'payment_failed', 'plan_ended', 'welcome', 'nonbuyer'));
insert into public.push_auto (kind, enabled, title, body, delay2, enabled_at)
values ('nonbuyer', true, 'Daily messages', '', 14, now())
on conflict (kind) do nothing;

-- The owner's list of daily messages, in order.
create table if not exists public.push_nonbuyer_msgs (
  pos     int primary key check (pos between 1 and 20),
  source  text not null check (source in ('trending', 'newest', 'premium', 'watched', 'channel', 'plan')),
  enabled boolean not null default true,
  title   text not null check (char_length(title) between 1 and 65),
  body    text not null default '' check (char_length(body) <= 240)
);
alter table public.push_nonbuyer_msgs enable row level security;
revoke all on public.push_nonbuyer_msgs from anon, authenticated;
insert into public.push_nonbuyer_msgs (pos, source, title, body) values
  (1, 'trending', '🔥 #1 today: {title}', '{views} people watched it in the last 24 hours. Don''t miss it.'),
  (2, 'plan', 'Unlock fast downloads today 🔥', 'Trial: 3 days of fast upload & 2 TB storage for just ₹{trial_price}.'),
  (3, 'newest', '🆕 Just dropped: {title}', 'New in {channel}. Be the first to watch it.'),
  (4, 'plan', 'Your 2 TB is waiting ⚡', 'Upload & download at full speed. Plans from ₹{from_price}.'),
  (5, 'premium', '🔒 Unlock {title}', 'Watch the full video with Premium. Start with 3 days for ₹{trial_price}.'),
  (6, 'plan', 'Best value: {best_plan} 💎', '₹{best_price} for {best_duration}. One-time UPI payment, no auto-renewal.'),
  (7, 'watched', 'Still thinking about {title}? 🍿', 'You watched the preview. Get the full video with Premium.'),
  (8, 'channel', '📺 {count} videos in {channel}', 'Including {title}. Tap to binge.')
on conflict (pos) do nothing;

-- One video for a phone (ads phones: all + ads content; others: all +
-- organic), by source. Returns nothing when there is no such video.
create or replace function public.push_nonbuyer_video(p_ads boolean, p_source text, p_install uuid)
returns table (post_id uuid, title text, channel_id uuid, channel text, image_url text, views int, n_channel int)
language sql stable security definer set search_path = ''
as $$
  with ok as (
    select p.id, p.title, p.published_at, p.channel_id, ch.name as channel,
           exists (select 1 from public.post_items i where i.post_id = p.id and i.is_premium) as prem
      from public.posts p
      join public.channels ch on ch.id = p.channel_id
     where p.status = 'published' and p.published_at <= now()
       and ch.status = 'published' and ch.review_status = 'approved'
       and p.audience::text in ('all', case when p_ads then 'ads' else 'organic' end)
       and ch.audience::text in ('all', case when p_ads then 'ads' else 'organic' end)
       and exists (select 1 from public.post_items i where i.post_id = p.id)
       and not exists (select 1 from public.post_items i where i.post_id = p.id and i.processing_status <> 'ready')
  ), v24 as (
    select ok.*, (select count(*)::int from public.analytics_events e
                   where e.content_id = ok.id and e.event in ('content_view', 'preview_view')
                     and e.created_at > now() - interval '24 hours') as views
      from ok
  ), last_seen as (
    select e.content_id from public.analytics_events e
     where e.install_id = p_install and e.event in ('content_view', 'preview_view') and e.content_id is not null
     order by e.created_at desc limit 1
  ), top_channel as (
    select channel_id from v24 group by channel_id order by sum(views) desc, count(*) desc limit 1
  ), pick as (
    select v24.* from v24
     where case p_source
             when 'trending' then true
             when 'newest' then true
             when 'premium' then v24.prem
             when 'watched' then v24.id = (select content_id from last_seen)
             when 'channel' then v24.channel_id = (select channel_id from top_channel)
             else false end
     order by case when p_source in ('trending', 'premium', 'channel') then v24.views end desc nulls last,
              v24.published_at desc
     limit 1
  )
  select pick.id, pick.title, pick.channel_id, pick.channel,
         (select s.storage_base || i.thumb_key from public.post_items i, public.push_settings s
           where i.post_id = pick.id and i.thumb_key is not null and s.id = 1 and s.storage_base like 'https://%'
           order by i.position limit 1),
         pick.views,
         (select count(*)::int from ok where ok.channel_id = pick.channel_id)
    from pick
$$;
revoke execute on function public.push_nonbuyer_video(boolean, text, uuid) from public, anon, authenticated;

-- Daily messages for the current hour (called every minute; once per phone
-- per slot).
create or replace function public.push_nonbuyer_tick()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  a     public.push_auto;
  s     public.push_settings;
  v_ist timestamp := now() at time zone 'Asia/Kolkata';
  v_n   int := 0;
  ph    record;
  m     public.push_nonbuyer_msgs;
  v     record;
  v_post uuid;
  v_img  text;
  v_chan uuid;
  v_list public.push_nonbuyer_msgs[];
  v_cnt int;
  v_i   int;
  k     int;
  v_vars jsonb;
  v_plans jsonb;
  v_key text;
begin
  select * into a from public.push_auto where kind = 'nonbuyer';
  select * into s from public.push_settings where id = 1;
  if not coalesce(a.enabled, false) or not (extract(hour from v_ist)::int = any (s.nb_hours)) then return 0; end if;
  select array_agg(x order by x.pos) into v_list from public.push_nonbuyer_msgs x where x.enabled;
  v_cnt := coalesce(array_length(v_list, 1), 0);
  if v_cnt = 0 then return 0; end if;

  select jsonb_build_object(
           'trial_price', (select price_inr from public.plans where active order by duration_days, price_inr limit 1),
           'from_price', (select min(price_inr) from public.plans where active),
           'best_plan', (select name from public.plans where active order by duration_days desc, price_inr desc limit 1),
           'best_price', (select price_inr from public.plans where active order by duration_days desc, price_inr desc limit 1),
           'best_duration', (select public.push_duration(duration_days) from public.plans where active
                              order by duration_days desc, price_inr desc limit 1))
    into v_plans;

  for ph in
    select t.install_id, t.user_id, (i.source = public.ad_source()) as ads
      from public.push_tokens t
      join public.installs i on i.install_id = t.install_id
     where i.created_at > now() - make_interval(days => coalesce(a.delay2, 14))
       and i.created_at >= a.enabled_at - make_interval(days => coalesce(a.delay2, 14))
       and (s.nb_audience = 'all' or i.source = public.ad_source())
       and i.notif_status = 'allowed'
       and (t.user_id is null or not public.is_admin_user(t.user_id))
       and (t.user_id is null or not exists (select 1 from public.payment_orders o
                                              where o.user_id = t.user_id and o.status = 'approved'))
       and (t.user_id is null or not exists (select 1 from public.subscriptions x where x.user_id = t.user_id))
       and not exists (select 1 from public.push_messages pm
                        where pm.kind <> 'manual' and pm.created_at > now() - interval '2 hours'
                          and (pm.target_install = t.install_id or (t.user_id is not null and pm.target_user = t.user_id)))
  loop
    v_key := 'nb:' || ph.install_id || ':' || to_char(v_ist, 'YYYY-MM-DD-HH24');
    continue when exists (select 1 from public.push_messages where dedupe_key = v_key);
    v_i := (select count(*) from public.push_messages pm where pm.kind = 'nonbuyer' and pm.target_install = ph.install_id)::int;
    -- The next message in the list; a content message without a fitting
    -- video moves on to the next one.
    for k in 0 .. v_cnt - 1 loop
      m := v_list[((v_i + k) % v_cnt) + 1];
      v_post := null; v_img := null; v_chan := null;
      if m.source = 'plan' then
        v_vars := v_plans;
        exit;
      end if;
      select * into v from public.push_nonbuyer_video(ph.ads, m.source, ph.install_id);
      if found and v.post_id is not null then
        v_post := v.post_id; v_img := v.image_url; v_chan := v.channel_id;
        v_vars := v_plans || jsonb_build_object('title', v.title, 'channel', v.channel,
                                                'views', coalesce(v.views, 0), 'count', coalesce(v.n_channel, 0));
        exit;
      end if;
      m := null;
    end loop;
    continue when m.pos is null;
    -- A small view count doesn't sell: say "most watched" instead.
    if m.body like '%{views}%' and coalesce((v_vars->>'views')::int, 0) < 20 then
      m.body := 'Today''s most watched on Flixvault. Don''t miss it.';
    end if;
    insert into public.push_messages (kind, title, body, image_url, action_type, action_id, audience,
                                      target_install, content_audience, ref_id, dedupe_key)
    values ('nonbuyer',
            left(public.push_render(m.title, v_vars), 65),
            left(public.push_render(m.body, v_vars), 240),
            v_img,
            case when m.source = 'plan' then 'premium' when m.source = 'channel' then 'channel' else 'post' end,
            case when m.source = 'channel' then v_chan::text else v_post::text end,
            'all', ph.install_id,
            case when ph.ads then 'ads' else 'organic' end,
            v_post,
            v_key)
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public.push_nonbuyer_tick() from public, anon, authenticated;

-- Is it quiet hours now (India time)?
create or replace function public.push_is_quiet()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select s.quiet_on and case
                     when s.quiet_from < s.quiet_to
                       then extract(hour from now() at time zone 'Asia/Kolkata')::int >= s.quiet_from
                            and extract(hour from now() at time zone 'Asia/Kolkata')::int < s.quiet_to
                     when s.quiet_from > s.quiet_to
                       then extract(hour from now() at time zone 'Asia/Kolkata')::int >= s.quiet_from
                            or extract(hour from now() at time zone 'Asia/Kolkata')::int < s.quiet_to
                     else false end
                   from public.push_settings s where s.id = 1), false)
$$;
revoke execute on function public.push_is_quiet() from public, anon, authenticated;

-- push_tick: automatic messages are created as before (so nothing is
-- missed), but during quiet hours they are not queued for sending. After
-- the quiet hours, held messages that no longer apply are dropped first.
create or replace function public.push_tick()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m public.push_messages;
  v_n int;
  v_url text;
  v_quiet boolean := public.push_is_quiet();
begin
  begin
    perform public.push_auto_tick();
  exception when others then
    raise warning 'push auto: %', sqlerrm;
  end;
  begin
    perform public.push_nonbuyer_tick();
  exception when others then
    raise warning 'push nonbuyer: %', sqlerrm;
  end;

  if not v_quiet then
    -- Held payment / plan / daily messages for someone who paid since.
    update public.push_messages pm
       set status = 'cancelled'
     where pm.status = 'scheduled' and pm.kind <> 'manual'
       and pm.kind in ('payment_reminder', 'payment_reminder_2', 'payment_failed', 'plan_ending',
                       'plan_ended', 'plan_ended_2', 'nonbuyer')
       and pm.scheduled_at < now() - interval '2 minutes'
       and exists (select 1 from public.payment_orders o
                    where o.status = 'approved' and o.verified_at > pm.created_at
                      and o.user_id = coalesce(pm.target_user,
                                               (select t.user_id from public.push_tokens t
                                                 where t.install_id = pm.target_install)));
    -- Several held messages for one person: only the newest goes out.
    update public.push_messages pm
       set status = 'cancelled'
     where pm.status = 'scheduled' and pm.kind <> 'manual'
       and (pm.target_user is not null or pm.target_install is not null)
       and pm.scheduled_at < now() - interval '2 minutes'
       and exists (select 1 from public.push_messages n
                    where n.status = 'scheduled' and n.kind <> 'manual' and n.id <> pm.id
                      and n.created_at > pm.created_at
                      and ((pm.target_user is not null and n.target_user = pm.target_user)
                           or (pm.target_install is not null and n.target_install = pm.target_install)));
  end if;

  for m in select * from public.push_messages
            where status = 'scheduled' and scheduled_at <= now()
              and (kind = 'manual' or not v_quiet)
            order by scheduled_at
            for update skip locked
  loop
    insert into public.push_deliveries (message_id, install_id, token)
    select m.id, a.install_id, a.token from public.push_targets(m) a
    on conflict do nothing;
    get diagnostics v_n = row_count;
    update public.push_messages
       set status = case when v_n = 0 then 'sent' else 'sending' end,
           recipients = v_n,
           sent_at = case when v_n = 0 then now() end
     where id = m.id;
  end loop;

  update public.push_deliveries
     set status = case when attempts < 3 then 'queued' else 'failed' end,
         error = case when attempts < 3 then error else 'no answer from the sender' end
   where status = 'sending' and claimed_at < now() - interval '5 minutes';
  update public.push_messages pm
     set status = 'sent', sent_at = now()
   where pm.status = 'sending'
     and not exists (select 1 from public.push_deliveries d
                      where d.message_id = pm.id and d.status in ('queued', 'sending'));

  if not exists (select 1 from public.push_deliveries where status = 'queued') then return; end if;
  select function_url into v_url from public.push_settings where id = 1;
  if v_url is null or to_regclass('net.http_request_queue') is null then return; end if;
  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := ''{"Content-Type": "application/json"}''::jsonb)'
    using v_url;
end $$;
revoke execute on function public.push_tick() from public, anon, authenticated;

-- Admin: quiet hours + daily messages.
create or replace function public.admin_push_schedule_get()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_owner() then raise exception 'only the owner can change notifications'; end if;
  return jsonb_build_object(
    'quiet_on', (select quiet_on from public.push_settings where id = 1),
    'quiet_from', (select quiet_from from public.push_settings where id = 1),
    'quiet_to', (select quiet_to from public.push_settings where id = 1),
    'nb_hours', (select to_jsonb(nb_hours) from public.push_settings where id = 1),
    'nb_audience', (select nb_audience from public.push_settings where id = 1),
    'nb_enabled', (select enabled from public.push_auto where kind = 'nonbuyer'),
    'nb_days', (select delay2 from public.push_auto where kind = 'nonbuyer'),
    'nb_msgs', coalesce((select jsonb_agg(to_jsonb(x) order by x.pos) from public.push_nonbuyer_msgs x), '[]'::jsonb),
    'nb_reach', (select count(distinct t.install_id) from public.push_tokens t
                   join public.installs i on i.install_id = t.install_id, public.push_settings s, public.push_auto a
                  where s.id = 1 and a.kind = 'nonbuyer'
                    and i.created_at > now() - make_interval(days => coalesce(a.delay2, 14))
                    and (s.nb_audience = 'all' or i.source = public.ad_source())
                    and i.notif_status = 'allowed'
                    and (t.user_id is null or not public.is_admin_user(t.user_id))
                    and (t.user_id is null or not exists (select 1 from public.payment_orders o
                                                           where o.user_id = t.user_id and o.status = 'approved'))
                    and (t.user_id is null or not exists (select 1 from public.subscriptions x where x.user_id = t.user_id))),
    'nb_sent_7d', (select count(*) from public.push_messages where kind = 'nonbuyer' and created_at > now() - interval '7 days'));
end $$;
revoke execute on function public.admin_push_schedule_get() from public, anon;
grant execute on function public.admin_push_schedule_get() to authenticated;

create or replace function public.admin_push_quiet_save(p_on boolean, p_from int, p_to int)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_owner() then raise exception 'only the owner can change notifications'; end if;
  if p_from not between 0 and 23 or p_to not between 0 and 23 or p_from = p_to then
    raise exception 'pick two different times';
  end if;
  update public.push_settings set quiet_on = coalesce(p_on, false), quiet_from = p_from, quiet_to = p_to where id = 1;
end $$;
revoke execute on function public.admin_push_quiet_save(boolean, int, int) from public, anon;
grant execute on function public.admin_push_quiet_save(boolean, int, int) to authenticated;

create or replace function public.admin_push_nonbuyer_save(
  p_enabled boolean, p_audience text, p_days int, p_hours int[], p_msgs jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  x jsonb;
begin
  if not public.is_owner() then raise exception 'only the owner can change notifications'; end if;
  if p_audience not in ('all', 'ads') then raise exception 'unknown audience'; end if;
  if p_days not between 1 and 90 then raise exception 'pick a number of days from the list'; end if;
  if coalesce(array_length(p_hours, 1), 0) = 0 or exists (select 1 from unnest(p_hours) h where h not between 0 and 23) then
    raise exception 'pick at least one time';
  end if;
  update public.push_settings
     set nb_audience = p_audience, nb_hours = (select array_agg(distinct h order by h) from unnest(p_hours) h)
   where id = 1;
  update public.push_auto
     set enabled = coalesce(p_enabled, false), delay2 = p_days,
         enabled_at = case when coalesce(p_enabled, false) and not enabled then now() else enabled_at end,
         updated_at = now()
   where kind = 'nonbuyer';
  for x in select * from jsonb_array_elements(coalesce(p_msgs, '[]'::jsonb)) loop
    if coalesce(trim(x->>'title'), '') = '' then raise exception 'every message needs a title'; end if;
    update public.push_nonbuyer_msgs
       set title = left(trim(x->>'title'), 65),
           body = left(coalesce(trim(x->>'body'), ''), 240),
           enabled = coalesce((x->>'enabled')::boolean, true)
     where pos = (x->>'pos')::int;
  end loop;
end $$;
revoke execute on function public.admin_push_nonbuyer_save(boolean, text, int, int[], jsonb) from public, anon;
grant execute on function public.admin_push_nonbuyer_save(boolean, text, int, int[], jsonb) to authenticated;
