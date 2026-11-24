-- Behaviour tests for the partner (Puffle) content feed.
-- Run by run_tests.sh after rls_test.sql (reuses its t.* helpers).
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = notice;
reset role;
select set_config('request.jwt.claim.sub', '', false);

-- Fixtures: one channel per audience, posts of each audience, one not-ready post.
insert into public.channels (id, name, audience, status, review_status) values
  ('10000000-0000-0000-0000-0000000000a1', 'PF All',     'all',     'published', 'approved'),
  ('10000000-0000-0000-0000-0000000000a2', 'PF Ads',     'ads',     'published', 'approved'),
  ('10000000-0000-0000-0000-0000000000a3', 'PF Organic', 'organic', 'published', 'approved'),
  ('10000000-0000-0000-0000-0000000000a4', 'PF Pending', 'all',     'published', 'pending');

insert into public.posts (id, channel_id, title, audience, status, published_at) values
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000a1', 'pf all post',      'all',     'published', now() - interval '3 hours'),
  ('20000000-0000-0000-0000-0000000000b2', '10000000-0000-0000-0000-0000000000a1', 'pf ads post',      'ads',     'published', now() - interval '2 hours'),
  ('20000000-0000-0000-0000-0000000000b3', '10000000-0000-0000-0000-0000000000a1', 'pf organic post',  'organic', 'published', now() - interval '1 hours'),
  ('20000000-0000-0000-0000-0000000000b4', '10000000-0000-0000-0000-0000000000a2', 'pf ads ch post',   'ads',     'published', now() - interval '4 hours'),
  ('20000000-0000-0000-0000-0000000000b5', '10000000-0000-0000-0000-0000000000a1', 'pf scheduled',     'all',     'published', now() + interval '1 day'),
  ('20000000-0000-0000-0000-0000000000b6', '10000000-0000-0000-0000-0000000000a1', 'pf processing',    'all',     'published', now() - interval '5 hours'),
  ('20000000-0000-0000-0000-0000000000b7', '10000000-0000-0000-0000-0000000000a4', 'pf pending chan',  'all',     'published', now() - interval '5 hours'),
  ('20000000-0000-0000-0000-0000000000b8', '10000000-0000-0000-0000-0000000000a1', 'pf draft',         'all',     'draft',     now() - interval '5 hours');

insert into public.post_items (id, post_id, kind, is_premium, bunny_video_id, thumb_key, processing_status) values
  ('30000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000b1', 'video', false, '40000000-0000-0000-0000-0000000000d1', 'th/1.jpg', 'ready'),
  ('30000000-0000-0000-0000-0000000000c2', '20000000-0000-0000-0000-0000000000b1', 'video', true,  '40000000-0000-0000-0000-0000000000d2', 'th/2.jpg', 'ready'),
  ('30000000-0000-0000-0000-0000000000c6', '20000000-0000-0000-0000-0000000000b6', 'video', false, '40000000-0000-0000-0000-0000000000d6', null,       'pending');

-- ---------------------------------------------------------------------------
-- Partner key + switch
-- ---------------------------------------------------------------------------
select t.ok(public.partner_auth('anything-long-enough-anything-long-enough') is null,
            'partner: no key yet -> no access');

select t.act_as('owner');
set role authenticated;
create temp table k as select public.admin_partner_new_key('puffle') as key;
reset role;
select t.ok((select key like 'fvp_%' and length(key) = 68 from k), 'partner: owner gets a new key');
select t.ok((select key_hash <> (select key from k) from public.partners where id = 'puffle'),
            'partner: key stored only as hash');
select t.ok(public.partner_auth((select key from k)) is null, 'partner: switch off -> key rejected');

set role authenticated;
select public.admin_partner_set_enabled('puffle', true);
reset role;
select t.ok(public.partner_auth((select key from k)) = 'puffle', 'partner: switch on + right key -> puffle');
select t.ok(public.partner_auth((select key from k) || 'x') is null, 'partner: wrong key rejected');

select t.act_as('organic_user');
set role authenticated;
select t.fails($$select public.admin_partner_set_enabled('puffle', false)$$, 'partner: non-owner cannot switch');
select t.fails($$select public.admin_partner_new_key('puffle')$$, 'partner: non-owner cannot make keys');
select t.fails($$select public.admin_partners()$$, 'partner: non-owner cannot read usage');
select t.fails($$select public.partner_explore('ads')$$, 'partner: app users cannot call the feed directly');
select t.fails($$select count(*) from public.partners$$, 'partner: app users cannot read partners table');
reset role;
select set_config('request.jwt.claim.sub', '', false);

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------
create temp table ex as
  select 'ads' a, jsonb_array_elements(public.partner_explore('ads', 'latest', 100)) j
  union all
  select 'organic', jsonb_array_elements(public.partner_explore('organic', 'latest', 100));

select t.ok((select count(*) from ex where a='ads' and j->>'title' in ('pf all post','pf ads post','pf ads ch post')) = 3,
            'partner: ads sees all + ads posts');
select t.ok(not exists (select 1 from ex where a='ads' and j->>'title' = 'pf organic post'),
            'partner: ads does not see organic posts');
select t.ok((select count(*) from ex where a='organic' and j->>'title' in ('pf all post','pf organic post')) = 2,
            'partner: organic sees all + organic posts');
select t.ok(not exists (select 1 from ex where a='organic' and j->>'title' in ('pf ads post','pf ads ch post')),
            'partner: organic does not see ads posts');
select t.ok(not exists (select 1 from ex where j->>'title' in ('pf scheduled','pf processing','pf pending chan','pf draft')),
            'partner: scheduled / processing / unapproved channel / draft hidden');
select t.ok(not exists (select 1 from ex, jsonb_array_elements(j->'items') i
                         where i ? 'bunny_video_id' or i ? 'media_key'),
            'partner: no video ids or storage keys leak');

select t.ok(jsonb_array_length(public.partner_explore('ads', 'all', 30, 0, 'pf ads ch')) = 1,
            'partner: search works');
select t.ok(public.partner_post('organic', '20000000-0000-0000-0000-0000000000b2') is null,
            'partner: ads post hidden from organic');
select t.ok(public.partner_post('ads', '20000000-0000-0000-0000-0000000000b2') is not null,
            'partner: ads post shown to ads');

select t.ok(exists (select 1 from jsonb_array_elements(public.partner_channels('ads')) c where c->>'name' = 'PF Ads'),
            'partner: ads channel listed for ads');
select t.ok(not exists (select 1 from jsonb_array_elements(public.partner_channels('organic')) c where c->>'name' in ('PF Ads','PF Pending')),
            'partner: ads/unapproved channels hidden from organic');
select t.ok(public.partner_channel('organic', '10000000-0000-0000-0000-0000000000a2') is null,
            'partner: organic cannot open ads channel');
select t.ok(jsonb_array_length(public.partner_channel('organic', '10000000-0000-0000-0000-0000000000a1')->'posts') = 2,
            'partner: channel page lists only visible posts');

-- ---------------------------------------------------------------------------
-- Playback rules
-- ---------------------------------------------------------------------------
select t.ok(public.partner_play_target('organic', '30000000-0000-0000-0000-0000000000c1', false, 'video')->>'video_id'
            = '40000000-0000-0000-0000-0000000000d1', 'partner: free item plays for anyone who can see it');
select t.fails($$select public.partner_play_target('organic', '30000000-0000-0000-0000-0000000000c2', false, 'video')$$,
            'partner: premium item needs Premium');
select t.ok(public.partner_play_target('organic', '30000000-0000-0000-0000-0000000000c2', true, 'video')->>'video_id'
            = '40000000-0000-0000-0000-0000000000d2', 'partner: Premium viewer gets the full video');
select t.ok((public.partner_play_target('ads', '30000000-0000-0000-0000-0000000000c2', false, 'preview')->>'auto')::boolean,
            'partner: ads viewer gets the automatic preview');
select t.fails($$select public.partner_play_target('organic', '30000000-0000-0000-0000-0000000000c2', false, 'preview')$$,
            'partner: organic non-Premium gets no preview (same as Flixvault)');
select t.fails($$select public.partner_play_target('ads', '30000000-0000-0000-0000-0000000000c6', true, 'video')$$,
            'partner: item of a hidden post cannot be played');

-- Views are logged apart from Flixvault's own counters.
create temp table vc as select view_count from public.posts where id = '20000000-0000-0000-0000-0000000000b1';
select public.partner_log_view('puffle', '20000000-0000-0000-0000-0000000000b1', '30000000-0000-0000-0000-0000000000c1', 'organic', false, 'video', 'u1');
select t.ok((select count(*) from public.partner_views where partner_id='puffle') = 1, 'partner: view logged');
select t.ok((select view_count from public.posts where id = '20000000-0000-0000-0000-0000000000b1') = (select view_count from vc),
            'partner: Flixvault view_count untouched');

select t.act_as('owner');
set role authenticated;
select t.ok((public.admin_partners()->0->>'views_7d')::int = 1, 'partner: usage card counts views');
reset role;
select set_config('request.jwt.claim.sub', '', false);

\echo 'Partner feed tests passed.'
