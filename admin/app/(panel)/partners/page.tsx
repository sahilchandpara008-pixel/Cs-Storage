import { Badge, Card, Flash, PageHeader, SectionTitle, Stat } from "@/components/ui";
import { requireOwner } from "@/lib/auth";
import { formatDate } from "@/lib/format";
import { setSharing } from "./actions";
import { KeyForm } from "./key-form";

type Partner = {
  id: string;
  name: string;
  enabled: boolean;
  has_key: boolean;
  key_hint: string | null;
  key_created_at: string | null;
  views_today: number;
  views_7d: number;
  viewers_7d: number;
  full_7d: number;
  last_view_at: string | null;
};

export default async function PartnersPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const sp = await searchParams;
  const { supabase } = await requireOwner();
  const { data, error } = await supabase.rpc("admin_partners");
  const partners = (data ?? []) as Partner[];

  return (
    <>
      <PageHeader
        title="Share with Puffle"
        subtitle="Let the Puffle app show your videos. Puffle's plays are counted here only – your own views, reports and Meta numbers are not affected."
      />
      <Flash ok={sp.ok} error={sp.error ?? (error ? error.message : undefined)} />
      {partners.map((p) => (
        <Card key={p.id} className="mb-5">
          <SectionTitle
            action={
              <form action={setSharing}>
                <input type="hidden" name="id" value={p.id} />
                <input type="hidden" name="enabled" value={p.enabled ? "0" : "1"} />
                <button
                  type="submit"
                  disabled={!p.enabled && !p.has_key}
                  className={`rounded-lg px-3.5 py-2 text-sm font-semibold disabled:opacity-50 ${
                    p.enabled ? "border border-gray-300 bg-white text-gray-800 hover:bg-gray-50" : "bg-brand-500 text-ink-900 hover:bg-brand-400"
                  }`}
                >
                  {p.enabled ? "Turn off" : "Turn on"}
                </button>
              </form>
            }
          >
            <span className="flex items-center gap-2">
              Share content with {p.name}
              <Badge tone={p.enabled ? "green" : "gray"}>{p.enabled ? "On" : "Off"}</Badge>
            </span>
          </SectionTitle>

          <div className="mb-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Stat label="Plays today" value={p.views_today} icon="▶" />
            <Stat label="Plays, last 7 days" value={p.views_7d} icon="📈" tone="purple" />
            <Stat label="Viewers, last 7 days" value={p.viewers_7d} icon="♙" tone="green" />
            <Stat label="Full videos, last 7 days" value={p.full_7d} icon="★" tone="amber" hint="the rest are previews" />
          </div>
          <p className="mb-4 text-xs text-gray-500">
            Last play: {p.last_view_at ? formatDate(p.last_view_at) : "none yet"}. Puffle viewers stream from your Bunny
            library, so their plays add to your Bunny bill.
          </p>

          <div className="border-t border-gray-200 pt-4">
            <p className="mb-2 text-sm font-medium text-gray-900">Secret key</p>
            <p className="mb-3 text-sm text-gray-500">
              {p.has_key
                ? `Key ending in …${p.key_hint ?? "????"}, made ${p.key_created_at ? formatDate(p.key_created_at) : ""}.`
                : "No key yet. Make one, then turn sharing on."}
            </p>
            <KeyForm id={p.id} hasKey={p.has_key} />
          </div>
        </Card>
      ))}
    </>
  );
}
