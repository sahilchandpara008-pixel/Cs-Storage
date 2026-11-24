-- push_tick was taking up to 2 minutes per run (and runs overlapped every
-- minute), starving the database so auth / the app / the admin timed out.
-- Same messages, same timing; only faster:
--   1. indexes for the per-video view counts and the "got a message in the
--      last 2 hours" checks;
--   2. only one push_tick runs at a time (an overlapping run exits at once);
--   3. messages for one phone / one user look that phone up directly instead
--      of scanning the whole audience.

create index if not exists analytics_events_content
  on public.analytics_events (content_id, created_at)
  where content_id is not null and event in ('content_view', 'preview_view');
create index if not exists push_messages_target_install
  on public.push_messages (target_install, created_at) where target_install is not null;
create index if not exists push_messages_target_user
  on public.push_messages (target_user, created_at) where target_user is not null;
create index if not exists push_messages_kind_install
  on public.push_messages (kind, target_install) where target_install is not null;

create or replace function public.push_targets(m public.push_messages)
returns table (install_id uuid, token text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if m.audience = 'all' and (m.target_install is not null or m.target_user is not null) then
    return query
      select t.install_id, t.token
        from public.push_tokens t
        join public.installs i on i.install_id = t.install_id
       where i.notif_status = 'allowed'
         and (m.target_install is null or t.install_id = m.target_install)
         and (m.target_user is null or t.user_id = m.target_user)
         and (m.content_audience is null
              or (m.content_audience = 'ads' and i.source = public.ad_source())
              or (m.content_audience = 'organic' and i.source is distinct from public.ad_source()));
    return;
  end if;
  return query
    select a.install_id, a.token
      from public.push_audience(m.audience, m.channel_ids, m.created_by) a
      join public.installs i on i.install_id = a.install_id
      join public.push_tokens t on t.install_id = a.install_id
     where (m.target_user is null or t.user_id = m.target_user)
       and (m.target_install is null or a.install_id = m.target_install)
       and (m.content_audience is null
            or (m.content_audience = 'ads' and i.source = public.ad_source())
            or (m.content_audience = 'organic' and i.source is distinct from public.ad_source()));
end $$;
revoke execute on function public.push_targets(public.push_messages) from public, anon, authenticated;

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
  -- Only one run at a time; the next minute's run picks up the rest.
  if not pg_try_advisory_xact_lock(hashtext('public.push_tick')) then return; end if;

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
            limit 500
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
