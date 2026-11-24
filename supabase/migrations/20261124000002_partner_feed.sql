-- Private content feed for partner apps (first partner: Puffle).
--
-- Purely additive: new tables + new functions only. Nothing that Flixvault's
-- own app, admin, reports, Meta events or cron jobs use is changed.
--
-- * public.partners          one row per partner. The secret key is stored
--                            only as a SHA-256 hash; the plain key is shown to
--                            the owner once, when it is created.
-- * public.partner_views     plays coming from a partner. Kept apart from
--                            analytics_events / posts.view_count / meta_events
--                            so Flixvault's numbers and Meta stay clean.
-- * partner_* functions      what the partner-feed edge function calls (service
--                            role only). The partner says which audience its
--                            viewer belongs to ('ads' | 'organic'); the rules
--                            are the same as Flixvault's own visibility rules:
--                            published, not scheduled, every item ready,
--                            channel approved + published, audience matches.
-- * admin_partner_* functions owner-only switch, key rotation and usage card.

create table if not exists public.partners (
  id          text primary key check (id ~ '^[a-z][a-z0-9_-]{1,31}$'),
  name        text not null,
  enabled     boolean not null default false,
  key_hash    text,                           -- hex sha256 of the key; never exposed
  key_hint    text,                           -- last 4 characters, for the admin page
  key_created_at timestamptz,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
alter table public.partners enable row level security;
revoke all on public.partners from anon, authenticated;

insert into public.partners (id, name) values ('puffle', 'Puffle')
on conflict (id) do nothing;

create table if not exists public.partner_views (
  id          bigint generated always as identity primary key,
  partner_id  text not null references public.partners (id) on delete cascade,
  post_id     uuid,
  item_id     uuid,
  audience    public.audience not null,
  premium     boolean not null default false,
  kind        text not null check (kind in ('video', 'preview')),
  viewer      text,                            -- partner's opaque user id (hashed by the partner)
  created_at  timestamptz not null default now()
);
create index if not exists partner_views_partner_time_idx
  on public.partner_views (partner_id, created_at desc);
alter table public.partner_views enable row level security;
revoke all on public.partner_views from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Visibility helpers (no auth.uid(): the caller is a server, not a viewer)
-- ---------------------------------------------------------------------------
create or replace function public.partner_audience_ok(p_req text, p_content public.audience)
returns boolean language sql immutable set search_path = '' as $$
  select p_content = 'all' or p_content::text = p_req
$$;

create or replace function public.partner_channel_ok(p_req text, p_channel_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.channels c
     where c.id = p_channel_id
       and c.review_status = 'approved'
       and c.status = 'published'
       and public.partner_audience_ok(p_req, c.audience))
$$;

create or replace function public.partner_post_ok(p_req text, p_post_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.posts p
     where p.id = p_post_id
       and p.status = 'published'
       and p.published_at <= now()
       and public.partner_audience_ok(p_req, p.audience)
       and public.partner_channel_ok(p_req, p.channel_id)
       and not exists (select 1 from public.post_items i
                        where i.post_id = p.id and i.processing_status <> 'ready'))
$$;

-- One post as JSON (only safe columns: no storage keys, no Bunny ids).
create or replace function public.partner_post_json(p public.posts)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'channel_id', p.channel_id,
    'folder_id', p.folder_id,
    'title', p.title,
    'caption', p.caption,
    'published_at', p.published_at,
    'view_count', p.view_count,
    'like_count', p.like_count,
    'channel', (select jsonb_build_object('id', c.id, 'name', c.name, 'icon_url', c.icon_url)
                  from public.channels c where c.id = p.channel_id),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id,
               'kind', i.kind,
               'is_premium', i.is_premium,
               'thumb_key', i.thumb_key,
               'duration_s', i.duration_s,
               'width', i.width,
               'height', i.height,
               'position', i.position,
               'playable', i.bunny_video_id is not null,
               'has_preview', coalesce(i.has_trailer, false)
                              and i.trailer_key is null)
             order by i.position)
        from public.post_items i where i.post_id = p.id), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- Partner auth
-- ---------------------------------------------------------------------------
create or replace function public.partner_auth(p_key text)
returns text language sql stable security definer set search_path = '' as $$
  select id from public.partners
   where enabled
     and key_hash is not null
     and length(coalesce(p_key, '')) >= 32
     and key_hash = encode(sha256(convert_to(p_key, 'UTF8')), 'hex')
$$;

-- ---------------------------------------------------------------------------
-- Feed reads
-- ---------------------------------------------------------------------------
-- Explore grid: tab = all | latest | popular | most_watched (+ optional search).
create or replace function public.partner_explore(
  p_audience text, p_tab text default 'all', p_limit int default 30,
  p_offset int default 0, p_search text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.partner_post_json(x.post) order by x.ord), '[]'::jsonb)
    from (
      select p as post, row_number() over (order by
               case when p_tab = 'popular'      then p.like_count end desc nulls last,
               case when p_tab = 'most_watched' then p.view_count end desc nulls last,
               p.published_at desc) ord
        from public.posts p
        cross join lateral (
          select '%' || replace(replace(replace(btrim(coalesce(p_search, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pat
        ) s
       where p.status = 'published'
         and p.published_at <= now()
         and public.partner_audience_ok(p_audience, p.audience)
         and public.partner_channel_ok(p_audience, p.channel_id)
         and not exists (select 1 from public.post_items i
                          where i.post_id = p.id and i.processing_status <> 'ready')
         and (btrim(coalesce(p_search, '')) = ''
              or p.title ilike s.pat
              or p.caption ilike s.pat
              or exists (select 1 from public.channels c
                          where c.id = p.channel_id and c.name ilike s.pat))
       order by
         case when p_tab = 'popular'      then p.like_count end desc nulls last,
         case when p_tab = 'most_watched' then p.view_count end desc nulls last,
         p.published_at desc
       limit greatest(1, least(coalesce(p_limit, 30), 100))
       offset greatest(0, coalesce(p_offset, 0))
    ) x
$$;

-- Channel list: sort = trending (followers) | latest | top (rating).
create or replace function public.partner_channels(
  p_audience text, p_sort text default 'trending', p_search text default null,
  p_limit int default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'description', c.description,
           'category', c.category, 'icon_url', c.icon_url,
           'members_count', c.members_count, 'rating', c.rating,
           'created_at', c.created_at) order by x.ord), '[]'::jsonb)
    from (
      select c.id, row_number() over (order by
               case when p_sort = 'latest' then extract(epoch from c.created_at) end desc nulls last,
               case when p_sort = 'top'    then c.rating end desc nulls last,
               c.members_count desc) ord
        from public.channels c
        cross join lateral (
          select '%' || replace(replace(replace(btrim(coalesce(p_search, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pat
        ) s
       where c.review_status = 'approved'
         and c.status = 'published'
         and public.partner_audience_ok(p_audience, c.audience)
         and (btrim(coalesce(p_search, '')) = ''
              or c.name ilike s.pat or c.description ilike s.pat or c.category ilike s.pat)
       order by 2
       limit greatest(1, least(coalesce(p_limit, 100), 100))
    ) x
    join public.channels c on c.id = x.id
$$;

-- One channel + its folders + its newest posts (paged with p_before).
create or replace function public.partner_channel(
  p_audience text, p_channel_id uuid, p_before timestamptz default null,
  p_limit int default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.partner_channel_ok(p_audience, p_channel_id) then null else
    jsonb_build_object(
      'channel', (select jsonb_build_object(
                    'id', c.id, 'name', c.name, 'description', c.description,
                    'category', c.category, 'icon_url', c.icon_url,
                    'members_count', c.members_count, 'rating', c.rating)
                    from public.channels c where c.id = p_channel_id),
      'folders', coalesce((select jsonb_agg(jsonb_build_object(
                    'id', f.id, 'name', f.name, 'cover_url', f.cover_url,
                    'position', f.position) order by f.position)
                    from public.channel_folders f where f.channel_id = p_channel_id), '[]'::jsonb),
      'posts', coalesce((select jsonb_agg(public.partner_post_json(p) order by p.published_at desc)
                    from (select p.* from public.posts p
                           where p.channel_id = p_channel_id
                             and (p_before is null or p.published_at < p_before)
                             and public.partner_post_ok(p_audience, p.id)
                           order by p.published_at desc
                           limit greatest(1, least(coalesce(p_limit, 50), 100))) p), '[]'::jsonb))
  end
$$;

create or replace function public.partner_post(p_audience text, p_post_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select public.partner_post_json(p)
    from public.posts p
   where p.id = p_post_id and public.partner_post_ok(p_audience, p.id)
$$;

-- What may be played. Same rules as Flixvault:
--   full video : free item, or the partner says the viewer is Premium
--   preview    : uploaded preview or automatic preview (start of the video),
--                for 'ads' viewers or Premium viewers (as bunny_preview_info)
-- Returns {video_id, auto} or raises 'Not allowed'.
create or replace function public.partner_play_target(
  p_audience text, p_item_id uuid, p_premium boolean, p_kind text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_item public.post_items;
begin
  select * into v_item from public.post_items where id = p_item_id;
  if not found or not public.partner_post_ok(p_audience, v_item.post_id) then
    raise exception 'Not allowed';
  end if;

  if p_kind = 'preview' then
    if not v_item.has_trailer or v_item.trailer_key is not null
       or not (p_audience = 'ads' or coalesce(p_premium, false)) then
      raise exception 'Not allowed';
    end if;
    if v_item.auto_preview then
      return jsonb_build_object('video_id', v_item.bunny_video_id, 'auto', true, 'post_id', v_item.post_id);
    end if;
    return jsonb_build_object('video_id', v_item.trailer_bunny_video_id, 'auto', false, 'post_id', v_item.post_id);
  end if;

  if v_item.bunny_video_id is null then
    raise exception 'Not playable';
  end if;
  if v_item.is_premium and not coalesce(p_premium, false) then
    raise exception 'Premium required';
  end if;
  return jsonb_build_object('video_id', v_item.bunny_video_id, 'auto', false, 'post_id', v_item.post_id);
end $$;

create or replace function public.partner_log_view(
  p_partner text, p_post_id uuid, p_item_id uuid, p_audience text,
  p_premium boolean, p_kind text, p_viewer text)
returns void language sql security definer set search_path = '' as $$
  insert into public.partner_views (partner_id, post_id, item_id, audience, premium, kind, viewer)
  values (p_partner, p_post_id, p_item_id, p_audience::public.audience,
          coalesce(p_premium, false), p_kind, left(p_viewer, 128))
$$;

-- Only the edge function (service role) may call the partner_* functions.
revoke execute on function public.partner_audience_ok(text, public.audience) from public, anon, authenticated;
revoke execute on function public.partner_channel_ok(text, uuid)              from public, anon, authenticated;
revoke execute on function public.partner_post_ok(text, uuid)                 from public, anon, authenticated;
revoke execute on function public.partner_post_json(public.posts)             from public, anon, authenticated;
revoke execute on function public.partner_auth(text)                          from public, anon, authenticated;
revoke execute on function public.partner_explore(text, text, int, int, text) from public, anon, authenticated;
revoke execute on function public.partner_channels(text, text, text, int)     from public, anon, authenticated;
revoke execute on function public.partner_channel(text, uuid, timestamptz, int) from public, anon, authenticated;
revoke execute on function public.partner_post(text, uuid)                    from public, anon, authenticated;
revoke execute on function public.partner_play_target(text, uuid, boolean, text) from public, anon, authenticated;
revoke execute on function public.partner_log_view(text, uuid, uuid, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public.partner_auth(text)                          to service_role;
grant execute on function public.partner_explore(text, text, int, int, text) to service_role;
grant execute on function public.partner_channels(text, text, text, int)     to service_role;
grant execute on function public.partner_channel(text, uuid, timestamptz, int) to service_role;
grant execute on function public.partner_post(text, uuid)                    to service_role;
grant execute on function public.partner_play_target(text, uuid, boolean, text) to service_role;
grant execute on function public.partner_log_view(text, uuid, uuid, text, boolean, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Owner-only admin: on/off switch, key, usage card
-- ---------------------------------------------------------------------------
create or replace function public.admin_partners()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'name', p.name, 'enabled', p.enabled,
             'has_key', p.key_hash is not null, 'key_hint', p.key_hint,
             'key_created_at', p.key_created_at, 'updated_at', p.updated_at,
             'views_today', (select count(*) from public.partner_views v
                              where v.partner_id = p.id
                                and v.created_at >= date_trunc('day', now())),
             'views_7d', (select count(*) from public.partner_views v
                           where v.partner_id = p.id
                             and v.created_at >= now() - interval '7 days'),
             'viewers_7d', (select count(distinct v.viewer) from public.partner_views v
                             where v.partner_id = p.id
                               and v.created_at >= now() - interval '7 days'),
             'full_7d', (select count(*) from public.partner_views v
                          where v.partner_id = p.id and v.kind = 'video'
                            and v.created_at >= now() - interval '7 days'),
             'last_view_at', (select max(v.created_at) from public.partner_views v
                               where v.partner_id = p.id))
           order by p.id)
      from public.partners p), '[]'::jsonb);
end $$;

create or replace function public.admin_partner_set_enabled(p_partner text, p_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  update public.partners
     set enabled = p_enabled, updated_at = now(), updated_by = auth.uid()
   where id = p_partner;
  if not found then raise exception 'Unknown partner'; end if;
end $$;

-- Makes a new key, stores only its hash and returns the plain key ONCE.
-- The old key stops working immediately.
create or replace function public.admin_partner_new_key(p_partner text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_key text := 'fvp_' || replace(gen_random_uuid()::text, '-', '')
                       || replace(gen_random_uuid()::text, '-', '');
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  update public.partners
     set key_hash = encode(sha256(convert_to(v_key, 'UTF8')), 'hex'),
         key_hint = right(v_key, 4),
         key_created_at = now(), updated_at = now(), updated_by = auth.uid()
   where id = p_partner;
  if not found then raise exception 'Unknown partner'; end if;
  return v_key;
end $$;

revoke execute on function public.admin_partners()                       from public, anon;
revoke execute on function public.admin_partner_set_enabled(text, boolean) from public, anon;
revoke execute on function public.admin_partner_new_key(text)             from public, anon;
grant execute on function public.admin_partners()                       to authenticated;
grant execute on function public.admin_partner_set_enabled(text, boolean) to authenticated;
grant execute on function public.admin_partner_new_key(text)             to authenticated;

notify pgrst, 'reload schema';
