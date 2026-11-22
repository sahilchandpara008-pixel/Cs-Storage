import type { ReactNode } from "react";
import { Button, Card, Field, Input, SectionTitle, Select, Table, Td, Th } from "@/components/ui";

type Kind = {
  enabled: boolean;
  title: string;
  body: string;
  nv_mode: string;
  interval_hours: number;
  title2: string | null;
  body2: string | null;
  delay1: number | null;
  delay2: number | null;
  video_post_id: string | null;
};
type Channel = {
  id: string;
  name: string;
  members: number;
  mode: string | null;
};
export type AutoSettings = {
  kinds: Record<string, Kind>;
  channels: Channel[];
  sent_7d: Record<string, number>;
};
export type AutoReportRow = {
  kind: string;
  sent: number;
  opened: number;
  paid: number;
  revenue: number;
};

const REPORT_LABEL: Record<string, string> = {
  payment_reminder: "🛒 Payment reminder (1st)",
  payment_reminder_2: "🛒 Payment reminder (2nd)",
  payment_failed: "❌ Payment failed",
  payment_approved: "✅ Payment approved",
  plan_ending: "⏰ Plan ending",
  plan_ended: "🔚 Plan ended (on the day)",
  plan_ended_2: "🔚 Plan ended (later)",
  welcome: "👋 Welcome video",
  come_back: "💤 Come back (1st)",
  come_back_2: "💤 Come back (2nd)",
  new_videos: "🎬 New videos",
};

function Toggle({ on }: { on: boolean }) {
  return (
    <label className="relative inline-flex shrink-0 cursor-pointer items-center gap-2 text-sm text-gray-700">
      <input type="checkbox" name="enabled" defaultChecked={on} className="peer sr-only" />
      <span className="relative h-6 w-11 rounded-full bg-gray-300 transition-colors peer-checked:bg-brand-500 after:absolute after:left-1 after:top-1 after:h-4 after:w-4 after:rounded-full after:bg-white after:transition-transform peer-checked:after:translate-x-5" />
      <span className="peer-checked:hidden">Off</span>
      <span className="hidden peer-checked:inline">On</span>
    </label>
  );
}

function Delay({ name, value, options, unit }: { name: string; value: number | null; options: number[]; unit: "hour" | "day" }) {
  const v = value ?? options[0];
  const list = options.includes(v) ? options : [...options, v].sort((a, b) => a - b);
  return (
    <Select name={name} defaultValue={String(v)} className="w-44!">
      {list.map((n) => (
        <option key={n} value={n}>
          {n} {unit}
          {n === 1 ? "" : "s"}
        </option>
      ))}
    </Select>
  );
}

const grid = "grid gap-3 sm:grid-cols-2";

// One automatic message: icon, name, what it does, its fields, on/off + Save.
function Row({
  kind,
  k,
  icon,
  title,
  sub,
  sent,
  saveAuto,
  children,
}: {
  kind: string;
  k: Kind | undefined;
  icon: string;
  title: string;
  sub: string;
  sent: number;
  saveAuto: (kind: string, formData: FormData) => Promise<void>;
  children: ReactNode;
}) {
  if (!k) return null;
  return (
    <form action={saveAuto.bind(null, kind)} className="flex flex-wrap gap-4 py-5 first:pt-0 last:pb-0">
      <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-brand-50 text-lg">{icon}</span>
      <div className="min-w-0 flex-1 basis-80 space-y-3">
        <div>
          <p className="font-semibold text-gray-900">
            {title} <span className="text-xs font-normal text-gray-500">· {sent} sent in the last 7 days</span>
          </p>
          <p className="text-sm text-gray-500">{sub}</p>
        </div>
        {children}
      </div>
      <div className="flex flex-col items-end gap-3">
        <Toggle on={k.enabled} />
        <Button type="submit">Save</Button>
      </div>
    </form>
  );
}

function Texts({ k, vars, label1, label2 }: { k: Kind; vars: string; label1?: string; label2?: string }) {
  const p1 = label1 ? `${label1} · ` : "";
  const p2 = label2 ? `${label2} · ` : "";
  return (
    <div className={grid}>
      <Field label={`${p1}Title`} hint={vars ? `You can use ${vars}` : undefined}>
        <Input name="title" defaultValue={k.title} maxLength={65} required />
      </Field>
      <Field label={`${p1}Text`}>
        <Input name="body" defaultValue={k.body} maxLength={240} />
      </Field>
      {label2 && (
        <>
          <Field label={`${p2}Title`}>
            <Input name="title2" defaultValue={k.title2 ?? ""} maxLength={65} required />
          </Field>
          <Field label={`${p2}Text`}>
            <Input name="body2" defaultValue={k.body2 ?? ""} maxLength={240} />
          </Field>
        </>
      )}
    </div>
  );
}

const inr = (n: number) => `₹${Math.round(n).toLocaleString("en-IN")}`;

// Automatic messages tab: results, one form per message, per-channel settings.
export function PushAuto({
  data,
  report,
  posts,
  saveAuto,
  saveChannelMode,
}: {
  data: AutoSettings;
  report: AutoReportRow[];
  posts: { id: string; name: string }[];
  saveAuto: (kind: string, formData: FormData) => Promise<void>;
  saveChannelMode: (channelId: string, formData: FormData) => Promise<void>;
}) {
  const kinds = data.kinds ?? {};
  const nv = kinds.new_videos;
  const sent = data.sent_7d ?? {};
  const defaultLabel = nv?.nv_mode === "members" ? "Channel members only" : "All app users";
  const order = Object.keys(REPORT_LABEL);
  const rows = [...report].sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind));
  const welcome = kinds.welcome;
  const picked = welcome?.video_post_id ?? "";
  return (
    <div className="space-y-5">
      <Card>
        <SectionTitle>Results · last 7 days</SectionTitle>
        {rows.length === 0 ? (
          <p className="text-sm text-gray-500">No automatic messages delivered in the last 7 days yet.</p>
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Message</Th>
                <Th>Sent</Th>
                <Th>Tapped</Th>
                <Th>Paid within 24 h</Th>
                <Th>Money from it</Th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {rows.map((r) => (
                <tr key={r.kind}>
                  <Td className="font-semibold text-gray-900">{REPORT_LABEL[r.kind] ?? r.kind}</Td>
                  <Td className="tabular-nums">{r.sent}</Td>
                  <Td className="whitespace-nowrap tabular-nums">
                    {r.opened}{" "}
                    <span className="text-xs text-gray-500">
                      ({r.sent > 0 ? Math.round((r.opened / r.sent) * 100) : 0}
                      %)
                    </span>
                  </Td>
                  <Td className="tabular-nums">{r.kind === "payment_approved" ? "—" : r.paid}</Td>
                  <Td className="tabular-nums font-semibold text-gray-900">
                    {r.kind === "payment_approved" ? "—" : inr(Number(r.revenue))}
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
        <p className="mt-3 text-xs text-gray-500">
          “Sent” counts phones that got the message. “Paid within 24 h” counts people who bought a plan in the 24 hours after it.
        </p>
      </Card>

      <Card>
        <SectionTitle>Payments &amp; plans</SectionTitle>
        <div className="divide-y divide-gray-200">
          <Row
            kind="payment_reminder"
            k={kinds.payment_reminder}
            icon="🛒"
            title="Payment reminder"
            sub="When someone started paying but didn't finish. Tapping opens Premium. Stops as soon as they pay."
            sent={sent.payment_reminder ?? 0}
            saveAuto={saveAuto}
          >
            {kinds.payment_reminder && (
              <>
                <div className="flex flex-wrap items-end gap-3">
                  <Field label="1st reminder after">
                    <Delay name="delay1" value={kinds.payment_reminder.delay1} options={[1, 2, 3]} unit="hour" />
                  </Field>
                  <Field label="2nd reminder after">
                    <Delay name="delay2" value={kinds.payment_reminder.delay2} options={[12, 24, 48]} unit="hour" />
                  </Field>
                </div>
                <Texts k={kinds.payment_reminder} vars="{plan} {price} {duration}" label1="1st" label2="2nd" />
              </>
            )}
          </Row>
          <Row
            kind="payment_failed"
            k={kinds.payment_failed}
            icon="❌"
            title="Payment failed"
            sub="Sent within minutes when the UPI app says the payment failed (at most once every 2 hours). Tapping opens Premium."
            sent={sent.payment_failed ?? 0}
            saveAuto={saveAuto}
          >
            {kinds.payment_failed && <Texts k={kinds.payment_failed} vars="{plan} {price} {duration}" />}
          </Row>
          <Row
            kind="payment_approved"
            k={kinds.payment_approved}
            icon="✅"
            title="Payment approved"
            sub="Sent as soon as a payment is approved (by the UPI app or by you)."
            sent={sent.payment_approved ?? 0}
            saveAuto={saveAuto}
          >
            {kinds.payment_approved && <Texts k={kinds.payment_approved} vars="{plan} {price} {duration} {end_date}" />}
          </Row>
          <Row
            kind="plan_ending"
            k={kinds.plan_ending}
            icon="⏰"
            title="Plan ending"
            sub="Sent 1 day before a plan ends (not if they already bought a longer one). Tapping opens Premium."
            sent={sent.plan_ending ?? 0}
            saveAuto={saveAuto}
          >
            {kinds.plan_ending && <Texts k={kinds.plan_ending} vars="{plan} {end_date}" />}
          </Row>
          <Row
            kind="plan_ended"
            k={kinds.plan_ended}
            icon="🔚"
            title="Plan ended"
            sub="Sent on the day a plan ends and again a few days later, unless they renewed. Tapping opens Premium."
            sent={sent.plan_ended ?? 0}
            saveAuto={saveAuto}
          >
            {kinds.plan_ended && (
              <>
                <Field label="2nd message after">
                  <Delay name="delay2" value={kinds.plan_ended.delay2} options={[2, 3, 5, 7]} unit="day" />
                </Field>
                <Texts k={kinds.plan_ended} vars="{plan} {from_price} (cheapest plan)" label1="On the day" label2="Later" />
              </>
            )}
          </Row>
        </div>
      </Card>

      <Card>
        <SectionTitle>Watching</SectionTitle>
        <div className="divide-y divide-gray-200">
          <Row
            kind="welcome"
            k={welcome}
            icon="👋"
            title="Welcome video"
            sub="Once per new install that hasn't watched anything yet, with the video's thumbnail. Tapping opens the video."
            sent={sent.welcome ?? 0}
            saveAuto={saveAuto}
          >
            {welcome && (
              <>
                <div className="flex flex-wrap items-end gap-3">
                  <Field label="Send after">
                    <Delay name="delay1" value={welcome.delay1} options={[1, 3, 6, 12]} unit="hour" />
                  </Field>
                  <Field label="Video">
                    <Select name="video_post_id" defaultValue={picked} className="w-72!">
                      <option value="">Most watched today (automatic)</option>
                      {picked && !posts.some((p) => p.id === picked) && <option value={picked}>Chosen video</option>}
                      {posts.map((p) => (
                        <option key={p.id} value={p.id}>
                          {p.name}
                        </option>
                      ))}
                    </Select>
                  </Field>
                </div>
                <Texts k={welcome} vars="{title} {channel}" />
                <p className="text-xs text-gray-500">
                  Ads installs get ads videos, organic installs get organic videos. A chosen video that a phone can&apos;t see is
                  swapped for the most watched one.
                </p>
              </>
            )}
          </Row>
          <Row
            kind="come_back"
            k={kinds.come_back}
            icon="💤"
            title="Come back"
            sub="To phones that haven't opened the app for a while, with the newest video's thumbnail. Tapping opens it."
            sent={sent.come_back ?? 0}
            saveAuto={saveAuto}
          >
            {kinds.come_back && (
              <>
                <div className="flex flex-wrap items-end gap-3">
                  <Field label="1st after">
                    <Delay name="delay1" value={kinds.come_back.delay1} options={[5, 7, 10]} unit="day" />
                  </Field>
                  <Field label="2nd after">
                    <Delay name="delay2" value={kinds.come_back.delay2} options={[14, 21, 30]} unit="day" />
                  </Field>
                </div>
                <Texts
                  k={kinds.come_back}
                  vars="{title} {channel} {count} (new videos) {more} (the rest)"
                  label1="1st"
                  label2="2nd"
                />
              </>
            )}
          </Row>
        </div>
      </Card>

      {nv && (
        <Card>
          <SectionTitle action={<span className="text-xs text-gray-500">{sent.new_videos ?? 0} sent in the last 7 days</span>}>
            New videos
          </SectionTitle>
          <form action={saveAuto.bind(null, "new_videos")} className="space-y-4">
            <div className="flex flex-wrap items-end gap-4">
              <Toggle on={nv.enabled} />
              <Field label="When a new video goes live, tell">
                <Select name="nv_mode" defaultValue={nv.nv_mode} className="w-56!">
                  <option value="all">All app users</option>
                  <option value="members">Channel members only</option>
                </Select>
              </Field>
              <Field label="At most">
                <Select name="interval_hours" defaultValue={String(nv.interval_hours)} className="w-56!">
                  {[1, 2, 4, 6, 12, 24].map((h) => (
                    <option key={h} value={h}>
                      1 message every {h} hour{h === 1 ? "" : "s"}
                    </option>
                  ))}
                </Select>
              </Field>
            </div>
            <div className={grid}>
              <Field label="Title (one new video)" hint="{channel} {title}">
                <Input name="title" defaultValue={nv.title} maxLength={65} required />
              </Field>
              <Field label="Text" hint="Several new videos together: “5 new videos in {channel}”">
                <Input name="body" defaultValue={nv.body} maxLength={240} />
              </Field>
            </div>
            <p className="text-xs text-gray-500">
              Sent with the video&apos;s thumbnail; tapping opens the video (or the channel when there are several). Ads-only
              videos go only to ads installs. Only videos that go live after you turn this on are announced.
            </p>
            <Button type="submit">Save</Button>
          </form>

          <div className="mt-5">
            <Table>
              <thead>
                <tr>
                  <Th>Channel</Th>
                  <Th>Members</Th>
                  <Th>Tell about new videos</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-200">
                {data.channels.map((c) => (
                  <tr key={c.id}>
                    <Td className="font-semibold text-gray-900">{c.name}</Td>
                    <Td className="tabular-nums">{c.members}</Td>
                    <Td>
                      <form action={saveChannelMode.bind(null, c.id)} className="flex flex-wrap items-center gap-2">
                        <Select name="mode" defaultValue={c.mode ?? "default"} className="w-56!">
                          <option value="default">Default ({defaultLabel})</option>
                          <option value="all">All app users</option>
                          <option value="members">Channel members only</option>
                          <option value="off">Off</option>
                        </Select>
                        <Button type="submit" variant="secondary">
                          Save
                        </Button>
                      </form>
                    </Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </div>
        </Card>
      )}
    </div>
  );
}
