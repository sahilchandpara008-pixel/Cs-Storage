import { Badge, Button, Card, Field, Input, SectionTitle, Select } from "@/components/ui";

type NbMsg = { pos: number; source: string; enabled: boolean; title: string; body: string };
export type ScheduleSettings = {
  quiet_on: boolean;
  quiet_from: number;
  quiet_to: number;
  nb_hours: number[];
  nb_audience: string;
  nb_enabled: boolean;
  nb_days: number;
  nb_msgs: NbMsg[];
  nb_reach: number;
  nb_sent_7d: number;
};

const SOURCE: Record<string, { label: string; vars: string }> = {
  trending: { label: "🔥 Trending video (most watched today)", vars: "{title} {channel} {views}" },
  newest: { label: "🆕 Newest video", vars: "{title} {channel}" },
  premium: { label: "🔒 Top Premium video", vars: "{title} {channel} {trial_price}" },
  watched: { label: "🍿 Last video they watched", vars: "{title} {channel}" },
  channel: { label: "📺 Busiest channel", vars: "{channel} {count} {title}" },
  plan: { label: "👑 Plan reminder (opens Premium)", vars: "{trial_price} {from_price} {best_plan} {best_price} {best_duration}" },
};

const hourLabel = (h: number) => (h === 0 ? "12:00 midnight" : h === 12 ? "12:00 noon" : h < 12 ? `${h}:00 am` : `${h - 12}:00 pm`);
const HOURS = Array.from({ length: 24 }, (_, h) => h);

function Toggle({ name, on }: { name: string; on: boolean }) {
  return (
    <label className="relative inline-flex shrink-0 cursor-pointer items-center gap-2 text-sm text-gray-700">
      <input type="checkbox" name={name} defaultChecked={on} className="peer sr-only" />
      <span className="relative h-6 w-11 rounded-full bg-gray-300 transition-colors peer-checked:bg-brand-500 after:absolute after:left-1 after:top-1 after:h-4 after:w-4 after:rounded-full after:bg-white after:transition-transform peer-checked:after:translate-x-5" />
      <span className="peer-checked:hidden">Off</span>
      <span className="hidden peer-checked:inline">On</span>
    </label>
  );
}

// Quiet hours (all automatic messages) + daily messages to people who haven't paid.
export function PushSchedule({
  data,
  saveQuiet,
  saveNonbuyer,
}: {
  data: ScheduleSettings;
  saveQuiet: (formData: FormData) => Promise<void>;
  saveNonbuyer: (formData: FormData) => Promise<void>;
}) {
  const slots = [...(data.nb_hours ?? [])].sort((a, b) => ((a + 24 - 9) % 24) - ((b + 24 - 9) % 24));
  while (slots.length < 4) slots.push(-1);
  return (
    <>
      <Card>
        <SectionTitle>Quiet hours</SectionTitle>
        <form action={saveQuiet} className="flex flex-wrap items-end gap-4">
          <Toggle name="quiet_on" on={data.quiet_on} />
          <Field label="Don't send between">
            <Select name="quiet_from" defaultValue={String(data.quiet_from)} className="w-40!">
              {HOURS.map((h) => (
                <option key={h} value={h}>
                  {hourLabel(h)}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="and">
            <Select name="quiet_to" defaultValue={String(data.quiet_to)} className="w-40!">
              {HOURS.map((h) => (
                <option key={h} value={h}>
                  {hourLabel(h)}
                </option>
              ))}
            </Select>
          </Field>
          <Button type="submit">Save</Button>
        </form>
        <p className="mt-3 text-sm text-gray-500">
          Applies to every automatic message. Anything due at night waits until the end of the quiet hours (India time); if the
          person paid in the meantime it isn&apos;t sent, and only the newest waiting message per person goes out. Messages you send
          yourself from “New message” are not held.
        </p>
      </Card>

      <Card>
        <SectionTitle action={<span className="text-xs text-gray-500">{data.nb_sent_7d} sent in the last 7 days</span>}>
          Daily messages to people who haven&apos;t paid
        </SectionTitle>
        <form action={saveNonbuyer} className="space-y-4">
          <div className="rounded-xl border border-gray-200 bg-gray-50 px-4 py-3 text-sm text-gray-700">
            Right now this reaches <b className="text-gray-900">{data.nb_reach.toLocaleString("en-IN")} phones</b> (never bought a
            plan, notifications allowed, installed within the days below).
          </div>
          <div className="flex flex-wrap items-end gap-3">
            <Toggle name="enabled" on={data.nb_enabled} />
            <Field label="Send to">
              <Select name="audience" defaultValue={data.nb_audience} className="w-56!">
                <option value="all">Everyone who hasn&apos;t paid</option>
                <option value="ads">Only ads installs</option>
              </Select>
            </Field>
            <Field label="For">
              <Select name="days" defaultValue={String(data.nb_days)} className="w-48!">
                {[3, 7, 14, 30].map((d) => (
                  <option key={d} value={d}>
                    {d} days after install
                  </option>
                ))}
              </Select>
            </Field>
          </div>
          <div className="flex flex-wrap items-end gap-3">
            {slots.map((h, i) => (
              <Field key={i} label={`Time ${i + 1}`}>
                <Select name="hour" defaultValue={String(h)} className="w-40!">
                  <option value="-1">— not used —</option>
                  {HOURS.map((x) => (
                    <option key={x} value={x}>
                      {hourLabel(x)}
                    </option>
                  ))}
                </Select>
              </Field>
            ))}
          </div>
          <p className="text-sm text-gray-500">
            Each phone gets the next message below at each time (India time). A time inside the quiet hours waits until they end.
            Skipped when the phone got another automatic message in the last 2 hours; stops as soon as they buy a plan.
          </p>
          <div className="space-y-3">
            {data.nb_msgs.map((m) => (
              <div key={m.pos} className="rounded-xl border border-gray-200 p-3">
                <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                  <p className="text-xs font-semibold uppercase tracking-wide text-gray-500">
                    Message {m.pos} · <span className="normal-case">{SOURCE[m.source]?.label ?? m.source}</span>
                  </p>
                  <label className="inline-flex items-center gap-2 text-xs text-gray-600">
                    <input type="checkbox" name={`on_${m.pos}`} defaultChecked={m.enabled} className="accent-brand-500" />
                    Send this one
                  </label>
                </div>
                <div className="grid gap-3 sm:grid-cols-2">
                  <Field label="Title" hint={`You can use ${SOURCE[m.source]?.vars ?? ""}`}>
                    <Input name={`title_${m.pos}`} defaultValue={m.title} maxLength={65} required />
                  </Field>
                  <Field label="Text">
                    <Input name={`body_${m.pos}`} defaultValue={m.body} maxLength={240} />
                  </Field>
                </div>
              </div>
            ))}
          </div>
          <p className="text-xs text-gray-500">
            Video messages show the video&apos;s thumbnail and open it. Ads installs only get ads / general videos, organic installs
            organic / general ones. When there&apos;s no fitting video, the next message is sent instead.
          </p>
          <div className="flex items-center gap-3">
            <Button type="submit">Save</Button>
            <Badge tone="purple">{slots.filter((h) => h >= 0).length} a day</Badge>
          </div>
        </form>
      </Card>
    </>
  );
}
