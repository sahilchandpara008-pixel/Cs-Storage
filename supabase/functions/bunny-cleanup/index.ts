// Owner-only: Bunny Stream videos that no post uses any more ("Storage
// cleanup" in the admin panel).
//
//   POST {action: "list"}              -> library totals + unused videos
//   POST {action: "delete", ids: [..]} -> deletes those videos
//   POST {action: "delete_all"}        -> deletes every unused video
//
// A video counts as used when any post_items row points at it (main video or
// trailer). Videos uploaded in the last 24 hours are never listed or deleted
// (an upload may still be in progress, its post not saved yet), and before
// each delete the database is checked again.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

type BunnyVideo = {
  guid: string;
  title: string;
  dateUploaded: string;
  status: number;
  storageSize: number;
  length: number;
  thumbnailFileName: string | null;
};

const DAY_MS = 24 * 60 * 60 * 1000;

function b64urlNoPad(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Same signed-URL scheme as bunny-stream-url (one token per video folder).
async function signedThumb(host: string, videoId: string, securityKey: string, file: string) {
  const pathDir = `/${videoId}/`;
  const expires = Math.floor(Date.now() / 1000) + 3600;
  const signingData = `token_path=${pathDir}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(securityKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(pathDir + String(expires) + signingData)),
  );
  return `https://${host}/bcdn_token=HS256-${b64urlNoPad(digest)}&token_path=${encodeURIComponent(pathDir)}&expires=${expires}${pathDir}${file}`;
}

function reason(v: BunnyVideo): string {
  if (v.status === 5) return "Processing failed";
  if (v.status === 6) return "Upload failed";
  if (v.status === 0 || v.storageSize === 0) return "Upload never finished";
  if (v.status === 1 || v.status === 2 || v.status === 3) return "Stuck in processing";
  return "Not used by any post";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: userData, error: userError } = await asUser.auth.getUser();
  if (userError || !userData.user) return json({ error: "not signed in" }, 401);
  const { data: isOwner } = await asUser.rpc("is_owner");
  if (!isOwner) return json({ error: "only the owner can clean up storage" }, 403);

  let action = "list";
  let ids: string[] = [];
  try {
    const body = await req.json();
    action = String(body.action ?? "list");
    ids = Array.isArray(body.ids) ? body.ids.map(String).slice(0, 500) : [];
  } catch {
    return json({ error: "invalid request body" }, 400);
  }

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const libraryId = Deno.env.get("BUNNY_STREAM_LIBRARY_ID")!;
  const apiKey = Deno.env.get("BUNNY_STREAM_API_KEY")!;

  // Every Bunny video id any post points at.
  async function usedIds(): Promise<Set<string>> {
    const used = new Set<string>();
    for (let from = 0; ; from += 1000) {
      const { data, error } = await admin
        .from("post_items")
        .select("bunny_video_id, trailer_bunny_video_id")
        .range(from, from + 999);
      if (error) throw new Error(error.message);
      for (const r of data ?? []) {
        if (r.bunny_video_id) used.add(String(r.bunny_video_id).toLowerCase());
        if (r.trailer_bunny_video_id) used.add(String(r.trailer_bunny_video_id).toLowerCase());
      }
      if (!data || data.length < 1000) break;
    }
    return used;
  }

  async function allVideos(): Promise<BunnyVideo[]> {
    const out: BunnyVideo[] = [];
    for (let page = 1; page <= 100; page++) {
      const res = await fetch(
        `https://video.bunnycdn.com/library/${libraryId}/videos?page=${page}&itemsPerPage=100&orderBy=date`,
        { headers: { AccessKey: apiKey, Accept: "application/json" } },
      );
      if (!res.ok) throw new Error(`Bunny answered ${res.status}`);
      const body = await res.json();
      const items = (body.items ?? []) as BunnyVideo[];
      out.push(...items);
      if (out.length >= Number(body.totalItems ?? 0) || items.length === 0) break;
    }
    return out;
  }

  const isUnused = (v: BunnyVideo, used: Set<string>) =>
    !used.has(v.guid.toLowerCase()) && Date.now() - Date.parse(v.dateUploaded + (v.dateUploaded.endsWith("Z") ? "" : "Z")) > DAY_MS;

  try {
    if (action === "list") {
      const [videos, used] = await Promise.all([allVideos(), usedIds()]);
      const unused = videos.filter((v) => isUnused(v, used));
      const host = Deno.env.get("BUNNY_STREAM_HOST");
      const tokenKey = Deno.env.get("BUNNY_STREAM_TOKEN_KEY");
      const rows = await Promise.all(
        unused.map(async (v) => ({
          id: v.guid,
          title: v.title || "Untitled",
          size: v.storageSize ?? 0,
          uploaded: v.dateUploaded,
          length: v.length ?? 0,
          reason: reason(v),
          thumb:
            host && tokenKey && v.thumbnailFileName && v.storageSize > 0
              ? await signedThumb(host, v.guid, tokenKey, v.thumbnailFileName)
              : null,
        })),
      );
      rows.sort((a, b) => b.size - a.size);
      return json({
        total: videos.length,
        total_size: videos.reduce((s, v) => s + (v.storageSize ?? 0), 0),
        used: videos.filter((v) => used.has(v.guid.toLowerCase())).length,
        recent: videos.filter((v) => !used.has(v.guid.toLowerCase()) && !isUnused(v, used)).length,
        unused_size: rows.reduce((s, r) => s + r.size, 0),
        unused: rows,
      });
    }

    if (action === "delete" || action === "delete_all") {
      const [videos, used] = await Promise.all([allVideos(), usedIds()]);
      const byId = new Map(videos.map((v) => [v.guid.toLowerCase(), v]));
      const targets =
        action === "delete_all"
          ? videos.filter((v) => isUnused(v, used))
          : ids.map((id) => byId.get(id.toLowerCase())).filter((v): v is BunnyVideo => !!v && isUnused(v, used));
      let deleted = 0;
      let freed = 0;
      for (const v of targets) {
        const res = await fetch(`https://video.bunnycdn.com/library/${libraryId}/videos/${v.guid}`, {
          method: "DELETE",
          headers: { AccessKey: apiKey },
        }).catch(() => null);
        if (res?.ok) {
          deleted++;
          freed += v.storageSize ?? 0;
        }
      }
      return json({ deleted, freed, skipped: (action === "delete_all" ? targets.length : ids.length) - deleted });
    }

    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 502);
  }
});
