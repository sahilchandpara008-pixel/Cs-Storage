-- More automatic messages (owner approved 1-5 and 7 of the preview; no
-- quiet hours: messages go out whenever they are due).
--
--   1. Payment reminder: a 2nd reminder (default 24 h after the payment try);
--      the 1st one's delay can be set (1-3 h).
--   2. Payment failed: within minutes of a UPI failure. Opens Premium.
--   3. Plan ended: on the day it ends and again N days later, unless renewed.
--   4. Welcome video: N hours after install when nothing was watched yet,
--      with today's most watched video (or one the owner picks).
--   5. Come back: 1st after N days away (now with the newest video), 2nd
--      after M days.
--   7. Admin report per message: sent, tapped, paid within 24 h, money.
--
-- Second messages use their own kind (payment_reminder_2, plan_ended_2,
-- come_back_2) so the report and History show them apart; their settings
-- live on the first one's row (title2 / body2 / delay2).

alter table public.push_auto drop constraint if exists push_auto_kind_check;
alter table public.push_auto add constraint push_auto_kind_check
  check (kind in ('payment_reminder', 'payment_approved', 'plan_ending', 'come_back', 'new_videos',
                  'payment_failed', 'plan_ended', 'welcome'));
alter table public.push_auto
  add column if not exists title2 text check (char_length(title2) <= 65),
  add column if not exists body2 text check (char_length(body2) <= 240),
  add column if not exists delay1 int check (delay1 between 1 and 90),
  add column if not exists delay2 int check (delay2 between 1 and 90),
  add column if not exists video_post_id uuid references public.posts (id) on delete set null;

update public.push_auto
   set delay1 = coalesce(delay1, 1), delay2 = coalesce(delay2, 24),
       title2 = coalesce(title2, 'Still want {plan}? ⏳'),
       body2 = coalesce(body2, '₹{price} for {duration} of fast upload & 2 TB storage. It takes 10 seconds.')
 where kind = 'payment_reminder';
update public.push_auto
   set delay1 = coalesce(delay1, 7), delay2 = coalesce(delay2, 14),
       title = 'New since your last visit',
       body = '{title} and {more} more videos are waiting.',
       title2 = coalesce(title2, 'You''re missing out 👀'),
       body2 = coalesce(body2, '{count} new videos since your last visit. Start with {title}.')
 where kind = 'come_back' and title = 'New videos are waiting';

insert into public.push_auto (kind, enabled, title, body, title2, body2, delay1, delay2, enabled_at) values
  ('payment_failed', true, 'Payment didn''t go through ❌',
   '₹{price} for {plan} wasn''t charged. Try again or pick another UPI app.', null, null, null, null, now()),
  ('plan_ended', true, 'Your {plan} has ended',
   'Renew now to get fast speed & 2 TB storage back.',
   'We miss you on {plan} 💛', 'Come back to fast upload & 2 TB storage from ₹{from_price}.', null, 3, now()),
  ('welcome', true, 'Start with today''s most watched 🔥', '{title} · {channel}', null, null, 3, null, now())
on conflict (kind) do nothing;

-- A video for one kind of phone (ads installs see all + ads content,
-- others all + organic), only what the app would show them. p_top: most
-- watched in the last 24 h (else newest); p_since: count videos that went
-- live since then.
create or replace function public.push_pick_video(p_ads boolean, p_top boolean, p_since timestamptz default null,
                                                  p_post uuid default null)
returns table (post_id uuid, title text, channel text, image_url text, n_since int)
language sql stable security definer set search_path = ''
as $$
  with ok as (
    select p.id, p.title, p.published_at, ch.name as channel
      from public.posts p
      join public.channels ch on ch.id = p.channel_id
     where p.status = 'published' and p.published_at <= now()
       and ch.status = 'published' and ch.review_status = 'approved'
       and p.audience::text in ('all', case when p_ads then 'ads' else 'organic' end)
       and ch.audience::text in ('all', case when p_ads then 'ads' else 'organic' end)
       and exists (select 1 from public.post_items i where i.post_id = p.id)
       and not exists (select 1 from public.post_items i where i.post_id = p.id and i.processing_status <> 'ready')
  ), pick as (
    select ok.* from ok
     order by (ok.id = p_post) desc,
              case when p_top then (select count(*) from public.analytics_events e
                                     where e.content_id = ok.id and e.event in ('content_view', 'preview_view')
                                       and e.created_at > now() - interval '24 hours') end desc nulls last,
              ok.published_at desc
     limit 1
  )
  select pick.id, pick.title, pick.channel,
         (select s.storage_base || i.thumb_key from public.post_items i, public.push_settings s
           where i.post_id = pick.id and i.thumb_key is not null and s.id = 1 and s.storage_base like 'https://%'
           order by i.position limit 1),
         (select count(*)::int from ok where p_since is not null and ok.published_at > p_since)
    from pick
$$;
revoke execute on function public.push_pick_video(boolean, boolean, timestamptz, uuid) from public, anon, authenticated;

create or replace function public.push_auto_tick()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  a public.push_auto;
  v_base text;
  c record;
  g record;
  v_ads boolean;
begin
  select storage_base into v_base from public.push_settings where id = 1;

  -- 1. Payment reminders: an unfinished payment try, nothing paid or waiting
  --    since, no active plan. 1st after delay1 hours (once a day per user),
  --    2nd after delay2 hours (once per try).
  begin
    select * into a from public.push_auto where kind = 'payment_reminder';
    if a.enabled then
      insert into public.push_messages (kind, title, body, action_type, audience, target_user, dedupe_key)
      select case when r.n = 1 then 'payment_reminder' else 'payment_reminder_2' end,
             left(public.push_render(case when r.n = 1 then a.title else a.title2 end, v), 65),
             left(public.push_render(case when r.n = 1 then a.body else coalesce(a.body2, '') end, v), 240),
             'premium', 'all', o.user_id,
             case when r.n = 1
                  then 'reminder:' || o.user_id || ':' || to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD')
                  else 'reminder2:' || o.id end
        from (values (1, coalesce(a.delay1, 1), 5), (2, coalesce(a.delay2, 24), 12)) r (n, h, win)
        join lateral (
              select distinct on (o.user_id) o.id, o.user_id, o.created_at, pl.name, pl.price_inr, pl.duration_days
                from public.payment_orders o join public.plans pl on pl.id = o.plan_id
               where o.status in ('initiated', 'failed', 'cancelled')
                 and o.created_at between now() - make_interval(hours => r.h + r.win) and now() - make_interval(hours => r.h)
                 and o.created_at >= coalesce(a.enabled_at, now())
               order by o.user_id, o.created_at desc) o on true,
             lateral (select jsonb_build_object('plan', o.name, 'price', o.price_inr,
                                                'duration', public.push_duration(o.duration_days)) v) x
       where (r.n = 1 or coalesce(a.title2, '') <> '')
         and not exists (select 1 from public.payment_orders y
                          where y.user_id = o.user_id and y.created_at > o.created_at - interval '1 minute'
                            and y.status in ('pending', 'approved'))
         -- The 2nd one only for the latest try (a newer try gets its own).
         and not exists (select 1 from public.payment_orders y
                          where r.n = 2 and y.user_id = o.user_id and y.created_at > o.created_at)
         and not exists (select 1 from public.subscriptions s
                          where s.user_id = o.user_id and now() between s.starts_at and s.ends_at)
         and not public.is_admin_user(o.user_id)
         and exists (select 1 from public.push_tokens t where t.user_id = o.user_id)
      on conflict (dedupe_key) where dedupe_key is not null do nothing;
    end if;
  exception when others then
    raise warning 'push payment_reminder: %', sqlerrm;
  end;

  -- 2. Payment failed (UPI app said FAILURE) in the last 30 minutes; at most
  --    one per user every 2 hours, none if they paid since.
  begin
    select * into a from public.push_auto where kind = 'payment_failed';
    if a.enabled then
      insert into public.push_messages (kind, title, body, action_type, audience, target_user, dedupe_key)
      select 'payment_failed',
             left(public.push_render(a.title, v), 65), left(public.push_render(a.body, v), 240),
             'premium', 'all', o.user_id, 'failed:' || o.id
        from (select distinct on (o.user_id) o.id, o.user_id, o.created_at, pl.name, pl.price_inr, pl.duration_days
                from public.payment_orders o join public.plans pl on pl.id = o.plan_id
               where o.status = 'failed'
                 and o.updated_at > now() - interval '30 minutes'
                 and o.updated_at >= coalesce(a.enabled_at, now())
               order by o.user_id, o.updated_at desc) o,
             lateral (select jsonb_build_object('plan', o.name, 'price', o.price_inr,
                                                'duration', public.push_duration(o.duration_days)) v) x
       where not exists (select 1 from public.payment_orders y
                          where y.user_id = o.user_id and y.created_at > o.created_at
                            and y.status in ('pending', 'approved'))
         and not exists (select 1 from public.push_messages m
                          where m.kind = 'payment_failed' and m.target_user = o.user_id
                            and m.created_at > now() - interval '2 hours')
         and not public.is_admin_user(o.user_id)
         and exists (select 1 from public.push_tokens t where t.user_id = o.user_id)
      on conflict (dedupe_key) where dedupe_key is not null do nothing;
    end if;
  exception when others then
    raise warning 'push payment_failed: %', sqlerrm;
  end;

  -- 3. Payment approved (last 30 minutes).
  begin
    select * into a from public.push_auto where kind = 'payment_approved';
    if a.enabled then
      insert into public.push_messages (kind, title, body, action_type, audience, target_user, dedupe_key)
      select 'payment_approved',
             left(public.push_render(a.title, v), 65), left(public.push_render(a.body, v), 240),
             'home', 'all', o.user_id, 'approved:' || o.id
        from public.payment_orders o
        join public.plans pl on pl.id = o.plan_id
        left join public.subscriptions s on s.id = o.subscription_id,
             lateral (select jsonb_build_object(
                        'plan', pl.name, 'price', pl.price_inr, 'duration', public.push_duration(pl.duration_days),
                        'end_date', coalesce(to_char(s.ends_at at time zone 'Asia/Kolkata', 'FMDD Mon YYYY'), '')) v) x
       where o.status = 'approved'
         and o.verified_at > now() - interval '30 minutes'
         and o.verified_at >= coalesce(a.enabled_at, now())
         and exists (select 1 from public.push_tokens t where t.user_id = o.user_id)
      on conflict (dedupe_key) where dedupe_key is not null do nothing;
    end if;
  exception when others then
    raise warning 'push payment_approved: %', sqlerrm;
  end;

  -- 4. Plan ending tomorrow (and no other plan continues after it).
  begin
    select * into a from public.push_auto where kind = 'plan_ending';
    if a.enabled then
      insert into public.push_messages (kind, title, body, action_type, audience, target_user, dedupe_key)
      select 'plan_ending',
             left(public.push_render(a.title, v), 65), left(public.push_render(a.body, v), 240),
             'premium', 'all', s.user_id, 'ending:' || s.id
        from public.subscriptions s
        join public.plans pl on pl.id = s.plan_id,
             lateral (select jsonb_build_object(
                        'plan', pl.name,
                        'end_date', to_char(s.ends_at at time zone 'Asia/Kolkata', 'FMDD Mon YYYY')) v) x
       where s.ends_at between now() + interval '20 hours' and now() + interval '28 hours'
         and not exists (select 1 from public.subscriptions s2
                          where s2.user_id = s.user_id and s2.id <> s.id and s2.ends_at > s.ends_at)
         and not public.is_admin_user(s.user_id)
         and exists (select 1 from public.push_tokens t where t.user_id = s.user_id)
      on conflict (dedupe_key) where dedupe_key is not null do nothing;
    end if;
  exception when others then
    raise warning 'push plan_ending: %', sqlerrm;
  end;

  -- 5. Plan ended: within 12 hours of the end, and again delay2 days later;
  --    only while no newer plan exists.
  begin
    select * into a from public.push_auto where kind = 'plan_ended';
    if a.enabled then
      insert into public.push_messages (kind, title, body, action_type, audience, target_user, dedupe_key)
      select case when r.n = 1 then 'plan_ended' else 'plan_ended_2' end,
             left(public.push_render(case when r.n = 1 then a.title else a.title2 end, v), 65),
             left(public.push_render(case when r.n = 1 then a.body else coalesce(a.body2, '') end, v), 240),
             'premium', 'all', s.user_id,
             case when r.n = 1 then 'ended:' else 'ended2:' end || s.id
        from (values (1, 0), (2, coalesce(a.delay2, 3))) r (n, d)
        join public.subscriptions s
          on s.ends_at between now() - make_interval(days => r.d) - interval '12 hours'
                           and now() - make_interval(days => r.d)
        join public.plans pl on pl.id = s.plan_id,
             lateral (select jsonb_build_object(
                        'plan', pl.name,
                        'from_price', (select min(p2.price_inr) from public.plans p2 where p2.active)) v) x
       where (r.n = 1 or coalesce(a.title2, '') <> '')
         and s.ends_at >= coalesce(a.enabled_at, now()) - interval '12 hours'
         and not exists (select 1 from public.subscriptions s2
                          where s2.user_id = s.user_id and s2.id <> s.id and s2.ends_at > s.ends_at)
         and not public.is_admin_user(s.user_id)
         and exists (select 1 from public.push_tokens t where t.user_id = s.user_id)
      on conflict (dedupe_key) where dedupe_key is not null do nothing;
    end if;
  exception when others then
    raise warning 'push plan_ended: %', sqlerrm;
  end;

  -- 6. Welcome video: delay1 hours after install, nothing watched yet.
  begin
    select * into a from public.push_auto where kind = 'welcome';
    if a.enabled then
      for v_ads in select unnest(array[true, false]) loop
        select * into g from public.push_pick_video(v_ads, true, null, a.video_post_id);
        continue when g.post_id is null;
        insert into public.push_messages (kind, title, body, image_url, action_type, action_id, audience,
                                          target_install, content_audience, ref_id, dedupe_key)
        select 'welcome',
               left(public.push_render(a.title, v), 65), left(public.push_render(a.body, v), 240),
               g.image_url, 'post', g.post_id::text, 'all', i.install_id,
               case when v_ads then 'ads' else 'organic' end, g.post_id,
               'welcome:' || i.install_id
          from public.installs i
          join public.push_tokens t on t.install_id = i.install_id,
               lateral (select jsonb_build_object('title', g.title, 'channel', g.channel) v) x
         where i.created_at between now() - make_interval(hours => coalesce(a.delay1, 3) + 6)
                                and now() - make_interval(hours => coalesce(a.delay1, 3))
           and i.created_at >= coalesce(a.enabled_at, now())
           and (i.source = public.ad_source()) = v_ads
           and not exists (select 1 from public.analytics_events e
                            where e.install_id = i.install_id and e.event in ('content_view', 'preview_view'))
           and (t.user_id is null or not public.is_admin_user(t.user_id))
        on conflict (dedupe_key) where dedupe_key is not null do nothing;
      end loop;
    end if;
  exception when others then
    raise warning 'push welcome: %', sqlerrm;
  end;

  -- 7. Come back: delay1 days and delay2 days since the app was last opened
  --    (once each per absence), with the newest video for that phone.
  begin
    select * into a from public.push_auto where kind = 'come_back';
    if a.enabled then
      insert into public.push_messages (kind, title, body, image_url, action_type, action_id, audience,
                                        target_install, content_audience, ref_id, dedupe_key)
      with due as materialized (
        select r.n, t.install_id, (i.source = public.ad_source()) as ads, l.last_open
          from (values (1, coalesce(a.delay1, 7)), (2, coalesce(a.delay2, 14))) r (n, d)
          cross join public.push_tokens t
          join public.installs i on i.install_id = t.install_id
          join lateral (select max(e.created_at) as last_open from public.analytics_events e
                         where e.install_id = t.install_id and e.event = 'app_open') l on true
         where (r.n = 1 or coalesce(a.title2, '') <> '')
           and l.last_open < now() - make_interval(days => r.d)
           and l.last_open > now() - make_interval(days => r.d + 2)
           and (t.user_id is null or not public.is_admin_user(t.user_id))
           and not exists (select 1 from public.push_messages m
                            where m.dedupe_key = case when r.n = 1 then 'comeback:' else 'comeback2:' end
                                                 || t.install_id || ':' || to_char(l.last_open, 'YYYY-MM-DD'))
      )
      select case when due.n = 1 then 'come_back' else 'come_back_2' end,
             left(public.push_render(case when due.n = 1 then a.title else a.title2 end, v), 65),
             left(public.push_render(case when due.n = 1 then a.body else coalesce(a.body2, '') end, v), 240),
             vid.image_url,
             case when vid.post_id is null then 'home' else 'post' end, vid.post_id::text,
             'all', due.install_id,
             case when due.ads then 'ads' else 'organic' end, vid.post_id,
             case when due.n = 1 then 'comeback:' else 'comeback2:' end
               || due.install_id || ':' || to_char(due.last_open, 'YYYY-MM-DD')
        from due
        left join lateral public.push_pick_video(due.ads, false, due.last_open, null) vid on true,
             lateral (select greatest(coalesce(nullif(vid.n_since, 0), 1), 1) as cnt) k,
             lateral (select jsonb_build_object('title', coalesce(vid.title, 'New videos'),
                                                'channel', coalesce(vid.channel, 'Flixvault'),
                                                'count', k.cnt, 'more', greatest(k.cnt - 1, 0)) v) x
      on conflict (dedupe_key) where dedupe_key is not null do nothing;
    end if;
  exception when others then
    raise warning 'push come_back: %', sqlerrm;
  end;

  -- 8. New videos, per channel (unchanged).
  begin
    select * into a from public.push_auto where kind = 'new_videos';
    if a.enabled then
      for c in
        select ch.id, ch.name, ch.audience::text as audience, coalesce(o.mode, a.nv_mode) as mode
          from public.channels ch
          left join public.push_channel_auto o on o.channel_id = ch.id
         where ch.status = 'published' and coalesce(o.mode, a.nv_mode) <> 'off'
      loop
        continue when exists (select 1 from public.push_messages m
                               where m.kind = 'new_videos' and m.ref_id = c.id
                                 and m.created_at > now() - make_interval(hours => a.interval_hours));
        for g in
          select case when c.audience = 'all' then p.audience::text
                      when p.audience::text in ('all', c.audience) then c.audience
                      else 'none' end as aud,
                 count(*) as n,
                 array_agg(p.id) as ids,
                 (array_agg(p.id order by p.published_at desc))[1] as latest_id,
                 (array_agg(p.title order by p.published_at desc))[1] as latest_title
            from public.posts p
           where p.channel_id = c.id
             and p.status = 'published' and p.published_at <= now()
             and greatest(p.published_at, p.created_at) >= a.enabled_at
             and not exists (select 1 from public.post_items i
                              where i.post_id = p.id and i.processing_status <> 'ready')
             and exists (select 1 from public.post_items i where i.post_id = p.id)
             and not exists (select 1 from public.push_notified_posts np where np.post_id = p.id)
           group by 1
        loop
          insert into public.push_notified_posts (post_id) select unnest(g.ids) on conflict do nothing;
          continue when g.aud = 'none';
          insert into public.push_messages (kind, title, body, image_url, action_type, action_id, audience,
                                            channel_ids, content_audience, ref_id)
          values ('new_videos',
                  left(case when g.n = 1
                            then public.push_render(a.title, jsonb_build_object('channel', c.name, 'title', g.latest_title))
                            else g.n || ' new videos in ' || c.name end, 65),
                  left(case when g.n = 1
                            then public.push_render(a.body, jsonb_build_object('channel', c.name, 'title', g.latest_title))
                            else 'Including “' || g.latest_title || '”. Tap to watch.' end, 240),
                  (select v_base || i.thumb_key from public.post_items i
                    where i.post_id = g.latest_id and i.thumb_key is not null and v_base like 'https://%'
                    order by i.position limit 1),
                  case when g.n = 1 then 'post' else 'channel' end,
                  case when g.n = 1 then g.latest_id::text else c.id::text end,
                  case when c.mode = 'members' then 'channels' else 'all' end,
                  case when c.mode = 'members' then array[c.id] else '{}'::uuid[] end,
                  case when g.aud in ('ads', 'organic') then g.aud end,
                  c.id);
        end loop;
      end loop;
    end if;
  exception when others then
    raise warning 'push new_videos: %', sqlerrm;
  end;
end $$;
revoke execute on function public.push_auto_tick() from public, anon, authenticated;

-- Admin: settings incl. the new fields and the picked welcome video.
create or replace function public.admin_push_auto_get()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_owner() then raise exception 'only the owner can change notifications'; end if;
  return jsonb_build_object(
    'kinds', (select jsonb_object_agg(kind, jsonb_build_object(
                'enabled', enabled, 'title', title, 'body', body, 'nv_mode', nv_mode,
                'interval_hours', interval_hours, 'title2', title2, 'body2', body2,
                'delay1', delay1, 'delay2', delay2, 'video_post_id', video_post_id)) from public.push_auto),
    'channels', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', ch.id, 'name', ch.name, 'members', (select count(*) from public.channel_members cm
                                                             where cm.channel_id = ch.id),
                  'mode', o.mode) order by ch.name)
                from public.channels ch left join public.push_channel_auto o on o.channel_id = ch.id
               where ch.status = 'published'), '[]'::jsonb),
    'sent_7d', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
                  select regexp_replace(kind, '_2$', '') as k, count(*) as n from public.push_messages
                   where kind <> 'manual' and created_at > now() - interval '7 days' group by 1) x));
end $$;
revoke execute on function public.admin_push_auto_get() from public, anon;
grant execute on function public.admin_push_auto_get() to authenticated;

create or replace function public.admin_push_auto_save2(
  p_kind text, p_enabled boolean, p_title text, p_body text,
  p_title2 text default null, p_body2 text default null,
  p_delay1 int default null, p_delay2 int default null,
  p_video_post_id uuid default null, p_nv_mode text default null, p_interval_hours int default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_owner() then raise exception 'only the owner can change notifications'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'enter a title'; end if;
  if p_kind in ('payment_reminder', 'plan_ended', 'come_back') and coalesce(trim(p_title2), '') = '' then
    raise exception 'enter a title for the 2nd message';
  end if;
  if p_delay1 is not null and p_delay1 not between 1 and 90 then raise exception 'pick a time from the list'; end if;
  if p_delay2 is not null and p_delay2 not between 1 and 90 then raise exception 'pick a time from the list'; end if;
  if p_kind = 'come_back' and coalesce(p_delay2, 14) <= coalesce(p_delay1, 7) then
    raise exception 'the 2nd message must come after the 1st';
  end if;
  update public.push_auto
     set enabled = coalesce(p_enabled, false),
         title = left(trim(p_title), 65),
         body = left(coalesce(trim(p_body), ''), 240),
         title2 = case when p_title2 is null then title2 else left(trim(p_title2), 65) end,
         body2 = case when p_body2 is null then body2 else left(trim(p_body2), 240) end,
         delay1 = coalesce(p_delay1, delay1),
         delay2 = coalesce(p_delay2, delay2),
         video_post_id = case when p_kind = 'welcome' then p_video_post_id else video_post_id end,
         nv_mode = coalesce(p_nv_mode, nv_mode),
         interval_hours = coalesce(p_interval_hours, interval_hours),
         enabled_at = case when coalesce(p_enabled, false) and not enabled then now() else enabled_at end,
         updated_at = now()
   where kind = p_kind;
  if not found then raise exception 'unknown message type'; end if;
end $$;
revoke execute on function public.admin_push_auto_save2(text, boolean, text, text, text, text, int, int, uuid, text, int)
  from public, anon;
grant execute on function public.admin_push_auto_save2(text, boolean, text, text, text, text, int, int, uuid, text, int)
  to authenticated;

-- Admin report: per automatic message over the last p_days days, phones it
-- reached, taps, people who paid within 24 h of getting it and that money.
create or replace function public.admin_push_auto_report(p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_owner() then raise exception 'only the owner can see notification results'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('kind', kind, 'sent', sent, 'opened', opened, 'paid', paid,
                                        'revenue', revenue) order by sent desc)
      from (
        select m.kind,
               count(*) as sent,
               count(*) filter (where d.opened_at is not null) as opened,
               count(distinct o.user_id) as paid,
               coalesce(sum(o.amount_paise) filter (where o.rn = 1), 0) / 100 as revenue
          from public.push_messages m
          join public.push_deliveries d on d.message_id = m.id and d.status = 'sent'
          left join public.push_tokens t on t.install_id = d.install_id
          left join lateral (
                select y.user_id, y.amount_paise, 1 as rn
                  from public.payment_orders y
                 where y.user_id = coalesce(m.target_user, t.user_id)
                   and y.status = 'approved'
                   and y.verified_at between d.sent_at and d.sent_at + interval '24 hours'
                 order by y.verified_at limit 1) o on true
         where m.kind <> 'manual'
           and d.sent_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)))
         group by m.kind) x), '[]'::jsonb);
end $$;
revoke execute on function public.admin_push_auto_report(int) from public, anon;
grant execute on function public.admin_push_auto_report(int) to authenticated;
