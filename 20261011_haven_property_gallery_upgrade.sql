-- Haven property photo gallery upgrade. Safe to run once in the Supabase SQL Editor.
-- Stores public photo URLs for a property gallery; the first photo remains the cover.
alter table public.properties
  add column if not exists gallery_urls jsonb not null default '[]'::jsonb;

-- The public listing page needs this one new field in addition to the existing approved column grants.
grant select (gallery_urls) on public.properties to anon, authenticated;

-- Hosts may update the gallery on their own draft/rejected listings only, matching the existing RLS policy.
grant update (gallery_urls, image_url) on public.properties to authenticated;
