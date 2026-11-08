import { supabase } from "./supabase";

/**
 * "Download my data" (launch audit M12, GDPR and UK GDPR access and portability): the caller's
 * own rows from export_my_data() (migration 78), saved as a JSON file on the device.
 */
export function exportFileName(now: Date = new Date()): string {
  return `activity-planet-data-${now.toISOString().slice(0, 10)}.json`;
}

export async function downloadMyData(): Promise<void> {
  const { data, error } = await supabase.rpc("export_my_data");
  if (error) throw error;
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  try {
    const a = document.createElement("a");
    a.href = url;
    a.download = exportFileName();
    document.body.appendChild(a);
    a.click();
    a.remove();
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
}
