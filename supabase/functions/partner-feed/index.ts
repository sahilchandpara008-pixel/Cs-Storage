// Private content feed for partner apps (Puffle).
//
// Called only by the partner's SERVER (never by an app), with the partner's
// secret key in the "x-partner-key" header. The key is checked against a hash
// in public.partners, and the owner's on/off switch ("Share content with
// Puffle") is part of that check -- switching it off cuts the feed at once.
//
// The partner tells us which audience its viewer belongs to ("ads" or
// "organic") and whether the viewer is Premium in the partner's own app.
// What is visible and what may be played is decided by the partner_*
// database functions, which follow Flixvault's own rules.
//
// Plays are logged in public.partner_views only: Flixvault's own view counts,
// analytics and Meta events are not touched.
//
// Request: POST JSON { action, audience, ... }
//   explore  { tab?: all|latest|popular|most_watched, offset?, limit?, search? }
//   channels { sort?: trending|latest|top, search? }
//   channel  { channel_id, before? }
//   post     { post_id }
//   play     { item_id, kind: video|preview, premium: bool, viewer?: string }
import { createClient } from "jsr:@supabase/supabase-js@2";

const THUMB_BASE = () => `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/public/`;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function b64urlNoPad(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Same signing as bunny-stream-url (Bunny directory token, 1 hour).
async function signBunnyDirectoryUrl(host: string, videoId: string, securityKey: string, file: string) {
  const pathDir = `/${videoId}/`;
  const expires = Math.floor(Date.now() / 1000) + 3600;
  const signingData = `token_path=${pathDir}`;
  const message = pathDir + String(expires) + signingData;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(securityKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  const token = "HS256-" + b64urlNoPad(digest);
  return `https://${host}/bcdn_token=${token}&token_path=${encodeURIComponent(pathDir)}&expires=${expires}${pathDir}${file}`;
}

// Same token format as bunny-stream-url's automatic preview (served by bunny-preview).
async function makePreviewToken(claims: { v: string; e: number; p: string }): Promise<string> {
  const enc = new TextEncoder();
  const body = b64urlNoPad(enc.encode(JSON.stringify(claims)));
  const key = await crypto.subtle.importKey(
    "raw", enc.encode("flixvault-preview:" + Deno.env.get("BUNNY_STREAM_TOKEN_KEY")!),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
  return `${body}.${b64urlNoPad(sig)}`;
}

// Adds absolute thumbnail URLs so the partner never needs Flixvault's URL layout.
function withThumbs(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(withThumbs);
  if (v && typeof v === "object") {
    const o: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      if (k === "thumb_key") {
        o.thumb_url = typeof val === "string" && val ? THUMB_BASE() + val : null;
      } else {
        o[k] = withThumbs(val);
      }
    }
    return o;
  }
  return v;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const key = req.headers.get("x-partner-key") ?? "";
  if (key.length < 32 || key.length > 200) return json({ error: "unauthorized" }, 401);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const { data: partner, error: authError } = await admin.rpc("partner_auth", { p_key: key });
  if (authError) return json({ error: "unavailable" }, 503);
  if (!partner) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid request body" }, 400);
  }

  const audience = body.audience === "ads" ? "ads" : body.audience === "organic" ? "organic" : null;
  if (!audience) return json({ error: "audience must be ads or organic" }, 400);
  const str = (v: unknown, max = 100) => (typeof v === "string" ? v.slice(0, max) : null);
  const int = (v: unknown, d: number) => (Number.isFinite(Number(v)) ? Math.trunc(Number(v)) : d);
  const uuid = (v: unknown) => (typeof v === "string" && UUID.test(v) ? v : null);

  switch (body.action) {
    case "explore": {
      const tab = ["all", "latest", "popular", "most_watched"].includes(String(body.tab)) ? String(body.tab) : "all";
      const { data, error } = await admin.rpc("partner_explore", {
        p_audience: audience, p_tab: tab,
        p_limit: Math.min(Math.max(int(body.limit, 30), 1), 100),
        p_offset: Math.max(int(body.offset, 0), 0),
        p_search: str(body.search),
      });
      if (error) return json({ error: "query failed" }, 500);
      return json({ posts: withThumbs(data ?? []) });
    }
    case "channels": {
      const sort = ["trending", "latest", "top"].includes(String(body.sort)) ? String(body.sort) : "trending";
      const { data, error } = await admin.rpc("partner_channels", {
        p_audience: audience, p_sort: sort, p_search: str(body.search), p_limit: 100,
      });
      if (error) return json({ error: "query failed" }, 500);
      return json({ channels: data ?? [] });
    }
    case "channel": {
      const id = uuid(body.channel_id);
      if (!id) return json({ error: "channel_id required" }, 400);
      const before = typeof body.before === "string" && !isNaN(Date.parse(body.before)) ? body.before : null;
      const { data, error } = await admin.rpc("partner_channel", {
        p_audience: audience, p_channel_id: id, p_before: before, p_limit: 50,
      });
      if (error) return json({ error: "query failed" }, 500);
      if (!data) return json({ error: "not found" }, 404);
      return json(withThumbs(data));
    }
    case "post": {
      const id = uuid(body.post_id);
      if (!id) return json({ error: "post_id required" }, 400);
      const { data, error } = await admin.rpc("partner_post", { p_audience: audience, p_post_id: id });
      if (error) return json({ error: "query failed" }, 500);
      if (!data) return json({ error: "not found" }, 404);
      return json({ post: withThumbs(data) });
    }
    case "play": {
      const itemId = uuid(body.item_id);
      if (!itemId) return json({ error: "item_id required" }, 400);
      const kind = body.kind === "preview" ? "preview" : "video";
      const premium = body.premium === true;
      const { data, error } = await admin.rpc("partner_play_target", {
        p_audience: audience, p_item_id: itemId, p_premium: premium, p_kind: kind,
      });
      if (error) {
        const msg = error.message ?? "";
        const reason = msg.includes("Premium") ? "premium_required" : "not_allowed";
        return json({ error: reason }, 403);
      }
      const target = data as { video_id: string | null; auto: boolean; post_id: string };
      if (!target?.video_id) return json({ error: "not_allowed" }, 403);

      let url: string;
      if (kind === "preview" && target.auto) {
        const token = await makePreviewToken({ v: target.video_id, e: Math.floor(Date.now() / 1000) + 3600, p: "" });
        url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/bunny-preview/${token}/master.m3u8`;
      } else {
        url = await signBunnyDirectoryUrl(
          Deno.env.get("BUNNY_STREAM_HOST")!, target.video_id, Deno.env.get("BUNNY_STREAM_TOKEN_KEY")!, "playlist.m3u8",
        );
      }

      // Logging must never block playback.
      await admin.rpc("partner_log_view", {
        p_partner: partner, p_post_id: target.post_id, p_item_id: itemId, p_audience: audience,
        p_premium: premium, p_kind: kind, p_viewer: str(body.viewer, 128),
      }).then(() => {}, () => {});

      return json({ url, kind, expires_in: 3600 });
    }
    default:
      return json({ error: "unknown action" }, 400);
  }
});
