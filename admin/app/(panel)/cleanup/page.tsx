import { DeleteButton } from "@/components/delete-button";
import { Badge, Card, Empty, Flash, PageHeader, SectionTitle, Stat, Table, Td, Th } from "@/components/ui";
import { requireOwner } from "@/lib/auth";
import { deleteUnused } from "./actions";

type Row = { id: string; title: string; size: number; uploaded: string; length: number; reason: string; thumb: string | null };
type Data = { total: number; total_size: number; used: number; recent: number; unused_size: number; unused: Row[] };

const size = (b: number) => (b >= 1e9 ? `${(b / 1e9).toFixed(1)} GB` : b >= 1e6 ? `${Math.round(b / 1e6)} MB` : "0 MB");
const day = (iso: string) =>
  new Date(iso.endsWith("Z") ? iso : iso + "Z").toLocaleDateString("en-IN", {
    timeZone: "Asia/Kolkata",
    day: "numeric",
    month: "short",
    year: "numeric",
  });
// Bunny bills storage at about $0.02 per GB per month.
const perMonth = (b: number) => `≈ ₹${Math.max(1, Math.round((b / 1e9) * 0.02 * 88))} / month`;

export default async function CleanupPage({ searchParams }: { searchParams: Promise<{ ok?: string; error?: string }> }) {
  const sp = await searchParams;
  const { supabase } = await requireOwner();
  const { data, error } = await supabase.functions.invoke("bunny-cleanup", { body: { action: "list" } });
  const d = (data ?? null) as Data | null;
  const failed = error || !d || (data as { error?: string })?.error;

  return (
    <>
      <PageHeader
        title="Storage cleanup"
        subtitle="Videos in your Bunny library that no post uses any more. Deleting them lowers your Bunny storage bill; the app is not affected."
      />
      <Flash ok={sp.ok} error={sp.error} />
      {failed ? (
        <Card>
          <p className="text-sm text-red-300">
            Couldn&apos;t read your Bunny library{(data as { error?: string })?.error ? `: ${(data as { error?: string }).error}` : ""}.
            Reload the page to try again.
          </p>
        </Card>
      ) : (
        <>
          <div className="mb-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Stat label="Videos in Bunny" value={d.total} icon="🎞" hint={`${size(d.total_size)} stored`} />
            <Stat label="Used by posts" value={d.used} icon="✅" tone="green" hint="videos + trailers" />
            <Stat label="Not used" value={d.unused.length} icon="🧹" tone="amber" hint="safe to delete" />
            <Stat label="You can free" value={size(d.unused_size)} icon="💾" tone="purple" hint={perMonth(d.unused_size)} />
          </div>
          {d.unused.length === 0 ? (
            <Empty icon="✨">Nothing to clean up – every video in Bunny is used by a post.</Empty>
          ) : (
            <Card>
              <SectionTitle
                action={
                  <form action={deleteUnused}>
                    <input type="hidden" name="all" value="1" />
                    <DeleteButton
                      label={`Delete all ${d.unused.length} unused`}
                      pendingLabel="Deleting…"
                      confirmText={`Delete all ${d.unused.length} unused videos (${size(d.unused_size)}) from Bunny? This can't be undone.`}
                    />
                  </form>
                }
              >
                Unused videos
              </SectionTitle>
              <form action={deleteUnused}>
                <Table>
                  <thead>
                    <tr>
                      <Th>
                        <span className="sr-only">Select</span>
                      </Th>
                      <Th>Video</Th>
                      <Th>Size</Th>
                      <Th>Uploaded</Th>
                      <Th>Why it&apos;s unused</Th>
                      <Th />
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-200">
                    {d.unused.map((r) => (
                      <tr key={r.id}>
                        <Td>
                          <input type="checkbox" name="ids" value={r.id} aria-label={`Select ${r.title}`} className="accent-brand-500" />
                        </Td>
                        <Td>
                          <div className="flex items-center gap-3">
                            {r.thumb ? (
                              // eslint-disable-next-line @next/next/no-img-element
                              <img src={r.thumb} alt="" className="h-10 w-16 shrink-0 rounded-md object-cover" loading="lazy" />
                            ) : (
                              <span className="block h-10 w-16 shrink-0 rounded-md bg-gray-200" />
                            )}
                            <span className="font-semibold text-gray-900">{r.title}</span>
                          </div>
                        </Td>
                        <Td className="whitespace-nowrap tabular-nums">{size(r.size)}</Td>
                        <Td className="whitespace-nowrap">{day(r.uploaded)}</Td>
                        <Td>
                          <Badge tone={r.reason === "Not used by any post" ? "gray" : "amber"}>{r.reason}</Badge>
                        </Td>
                        <Td>
                          <span className="[&>button]:whitespace-nowrap">
                            <DeleteButtonOne id={r.id} title={r.title} />
                          </span>
                        </Td>
                      </tr>
                    ))}
                  </tbody>
                </Table>
                <div className="mt-4 flex flex-wrap items-center gap-3">
                  <DeleteButton
                    label="Delete ticked videos"
                    pendingLabel="Deleting…"
                    confirmText="Delete the ticked videos from Bunny? This can't be undone."
                  />
                  <p className="text-xs text-gray-500">
                    Videos uploaded in the last 24 hours are never listed ({d.recent} right now), so an upload in progress
                    can&apos;t be deleted by mistake. Each video is checked again right before it&apos;s deleted.
                  </p>
                </div>
              </form>
            </Card>
          )}
        </>
      )}
    </>
  );
}

// A row's own Delete: a submit button of the list form carrying "one".
function DeleteButtonOne({ id, title }: { id: string; title: string }) {
  return (
    <DeleteButton
      label="Delete"
      pendingLabel="…"
      confirmText={`Delete "${title}" from Bunny? This can't be undone.`}
      name="one"
      value={id}
    />
  );
}
