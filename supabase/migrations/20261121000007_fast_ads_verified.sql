-- Explore / channel / feed were timing out (16 s for one Explore load for an
-- ads user; ~1,000 "statement timeout" errors a day): every post's
-- visibility check calls ads_verified() about twice, and each call decodes
-- the install referrer (~8 ms). The answer is the same for the whole
-- request, so it is now worked out once per transaction and reused.
-- Keyed by user id; set_config(..., true) is local to the transaction, so a
-- new request always starts fresh.
create or replace function public.ads_verified()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  k text := coalesce(auth.uid()::text, '');
  c text := current_setting('app.ads_verified', true);
  r boolean;
begin
  if c is not null and c <> '' and split_part(c, '|', 1) = k then
    return split_part(c, '|', 2) = 't';
  end if;
  r := not public.geo_blocked() and exists (
    select 1 from public.user_attribution ua
      join public.installs i on i.install_id = ua.first_touch_install_id
     where ua.user_id = auth.uid()
       and ua.first_touch_source = public.ad_source()
       and public.is_meta_ad_referrer(i.referrer_status, i.raw_referrer));
  perform set_config('app.ads_verified', k || '|' || case when r then 't' else 'f' end, true);
  return r;
end $$;
revoke execute on function public.ads_verified() from public;
grant execute on function public.ads_verified() to anon, authenticated;
