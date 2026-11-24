"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireOwner } from "@/lib/auth";
import { withMessage } from "@/lib/format";

export async function setSharing(formData: FormData) {
  const { supabase } = await requireOwner();
  const id = String(formData.get("id") ?? "");
  const on = formData.get("enabled") === "1";
  const { error } = await supabase.rpc("admin_partner_set_enabled", { p_partner: id, p_enabled: on });
  if (error) redirect(withMessage("/partners", "error", error.message));
  revalidatePath("/partners");
  redirect(withMessage("/partners", "ok", on ? "Sharing is on." : "Sharing is off. Puffle can no longer load your videos."));
}

// Returns the new key to the page once (never put in a URL or stored in plain text).
export async function newKey(_prev: { key?: string; error?: string }, formData: FormData) {
  const { supabase } = await requireOwner();
  const id = String(formData.get("id") ?? "");
  const { data, error } = await supabase.rpc("admin_partner_new_key", { p_partner: id });
  if (error) return { error: error.message };
  revalidatePath("/partners");
  return { key: String(data) };
}
