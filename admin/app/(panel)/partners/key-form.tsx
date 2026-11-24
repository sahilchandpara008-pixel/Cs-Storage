"use client";

import { useActionState } from "react";
import { CopyButton } from "@/components/copy-button";
import { newKey } from "./actions";

export function KeyForm({ id, hasKey }: { id: string; hasKey: boolean }) {
  const [state, action, pending] = useActionState(newKey, {} as { key?: string; error?: string });
  return (
    <div className="space-y-3">
      <form
        action={action}
        onSubmit={(e) => {
          if (hasKey && !confirm("Make a new key? The old key stops working right away, so Puffle must get the new one.")) {
            e.preventDefault();
          }
        }}
      >
        <input type="hidden" name="id" value={id} />
        <button
          type="submit"
          disabled={pending}
          className="rounded-lg border border-gray-300 bg-white px-3.5 py-2 text-sm font-medium text-gray-800 hover:bg-gray-50 disabled:opacity-50"
        >
          {pending ? "Making key…" : hasKey ? "Make a new key" : "Make key"}
        </button>
      </form>
      {state.error && <p className="text-sm text-red-600">{state.error}</p>}
      {state.key && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
          <p className="font-semibold">Copy this key now – it is shown only once.</p>
          <p className="mt-1">
            Paste it in Puffle&apos;s Supabase project as the secret <code className="font-mono">FLIXVAULT_PARTNER_KEY</code>{" "}
            (Edge Functions → Secrets). Don&apos;t send it in chat or email.
          </p>
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <code className="break-all rounded-md bg-white px-2 py-1 font-mono text-xs text-gray-900">{state.key}</code>
            <CopyButton text={state.key} />
          </div>
        </div>
      )}
    </div>
  );
}
