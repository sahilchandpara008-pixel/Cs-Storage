-- Installs were counted twice by Meta.
--
-- Since app 1.11.4 the Meta SDK inside the app reports each install to Meta
-- itself. The server also sent its own "MobileAppInstall" for the same phone
-- with a different event ID, so Meta counted both (22 Nov: Ads Manager 192
-- installs, real 132).
--
-- Now the server's MobileAppInstall waits 10 minutes (the app sends the SDK's
-- install ID right after start) and is skipped when the phone has the SDK
-- (installs.fb_anon_id is set). Older app versions without the SDK are still
-- reported by the server. "AppInstall" (our own custom event) is unchanged:
-- Meta does not count it as an install.

alter table public.meta_events drop constraint if exists meta_events_status_check;
alter table public.meta_events add constraint meta_events_status_check
  check (status in ('queued', 'sent', 'ok', 'failed', 'skipped'));

create or replace function public.meta_dispatch()
returns integer
language plpgsql security definer set search_path = ''
as $function$
declare
  s     public.meta_settings;
  v_ids bigint[];
  v_req bigint;
  v_n   int := 0;
begin
  if to_regclass('net.http_request_queue') is null then
    return 0;  -- pg_net not installed (local tests)
  end if;

  execute $q$
    update public.meta_events e
       set status = case when r.status_code between 200 and 299 then 'ok'
                         when e.attempts >= 5 then 'failed' else 'queued' end,
           response = left(coalesce(r.content::text, r.error_msg, ''), 1000)
      from net._http_response r
     where e.status = 'sent' and r.id = e.request_id
  $q$;
  update public.meta_events
     set status = case when attempts >= 5 then 'failed' else 'queued' end,
         response = coalesce(response, 'no response from Meta')
   where status = 'sent' and sent_at < now() - interval '10 minutes';

  perform public.meta_skip_sdk_installs();

  select * into s from public.meta_settings where id = 1;
  if not found or not s.enabled or s.pixel_id is null or s.access_token is null then
    return 0;
  end if;

  select array_agg(id order by id) into v_ids
    from (select id from public.meta_events
           where status = 'queued' and created_at < now() - interval '30 seconds'
             and (event_name <> 'MobileAppInstall' or created_at < now() - interval '10 minutes')
           order by id limit 50) q;
  if v_ids is null then return 0; end if;

  execute $q$
    select net.http_post(
      url     := 'https://graph.facebook.com/v21.0/' || $1 || '/events',
      body    := $2,
      params  := jsonb_build_object('access_token', $3),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 30000)
  $q$
  into v_req
  using s.pixel_id,
        jsonb_strip_nulls(jsonb_build_object(
          'data', (select jsonb_agg(public.meta_event_payload(e, s) order by e.id)
                     from public.meta_events e where e.id = any (v_ids)),
          'test_event_code', nullif(trim(coalesce(s.test_event_code, '')), ''))),
        s.access_token;

  update public.meta_events
     set status = 'sent', request_id = v_req, attempts = attempts + 1, sent_at = now()
   where id = any (v_ids);
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

-- Queued server installs of phones whose Meta SDK already reported the install.
create or replace function public.meta_skip_sdk_installs()
returns integer
language plpgsql security definer set search_path = ''
as $function$
declare
  v_n int;
begin
  update public.meta_events e
     set status = 'skipped', response = 'Meta SDK in the app reported this install'
    from public.installs i
   where e.status = 'queued' and e.event_name = 'MobileAppInstall'
     and i.install_id = e.install_id and i.fb_anon_id is not null;
  get diagnostics v_n = row_count;
  return v_n;
end $function$;
revoke all on function public.meta_skip_sdk_installs() from public, anon, authenticated;
revoke all on function public.meta_dispatch() from public, anon, authenticated;
