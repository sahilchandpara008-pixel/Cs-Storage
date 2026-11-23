"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireOwner } from "@/lib/auth";
import { withMessage } from "@/lib/format";

const gb = (bytes: number) => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.round(bytes / 1e6)} MB`);

// Deletes the chosen unused Bunny videos (a row's own Delete button sends
// "one"; the bulk button sends every ticked "ids"), or every unused video.
export async function deleteUnused(formData: FormData) {
  const { supabase } = await requireOwner();
  const one = String(formData.get("one") ?? "");
  const all = formData.get("all") === "1";
  const ids = one ? [one] : formData.getAll("ids").map(String).filter(Boolean);
  if (!all && ids.length === 0) redirect(withMessage("/cleanup", "error", "Tick the videos to delete first."));
  const { data, error } = await supabase.functions.invoke("bunny-cleanup", {
    body: all ? { action: "delete_all" } : { action: "delete", ids },
  });
  if (error || data?.error) redirect(withMessage("/cleanup", "error", data?.error ?? "Bunny didn't answer. Try again."));
  revalidatePath("/cleanup");
  const n = Number(data?.deleted ?? 0);
  redirect(
    withMessage(
      "/cleanup",
      "ok",
      n === 0
        ? "Nothing was deleted (the videos are in use again or already gone)."
        : `Deleted ${n} video${n === 1 ? "" : "s"}, freed ${gb(Number(data?.freed ?? 0))}.`,
    ),
  );
}
