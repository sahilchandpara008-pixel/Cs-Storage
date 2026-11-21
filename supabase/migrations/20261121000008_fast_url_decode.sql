-- url_decode() rebuilt the result one character at a time (bytea || per
-- character), ~50 ms for a long Meta install referrer, and the referrer
-- checks decode the same string several times. That made the admin
-- Dashboard numbers (admin_analytics) take 21 s and slowed every "came from
-- an ad" check. Same results in one pass: %XX -> byte, '+' -> space, a '%'
-- not followed by two hex digits stays '%'; null -> null. Checked equal on
-- every stored referrer (and decoded twice) before switching.
create or replace function public.url_decode(p text)
returns text language sql immutable set search_path = '' as $$
  select case when p is null then null else (
    select coalesce(convert_from(string_agg(
             case when m[1] ~ '^%[0-9A-Fa-f]{2}$' then decode(substr(m[1], 2, 2), 'hex')
                  else convert_to(replace(m[1], '+', ' '), 'UTF8') end, ''::bytea order by n), 'UTF8'), '')
      from regexp_matches(p, '%[0-9A-Fa-f]{2}|[^%]+|%', 'g') with ordinality as t(m, n)) end
$$;
