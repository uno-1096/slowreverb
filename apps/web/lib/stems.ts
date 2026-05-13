const STEMS_API = process.env.NEXT_PUBLIC_STEMS_URL ?? "http://localhost:8090";

export type StemName = "vocals" | "drums" | "bass" | "other";

export interface StemJob {
  id: string;
  status: "pending" | "processing" | "done" | "failed";
  stems: Record<string, string>;
  error?: string;
}

export async function separateStems(file: File): Promise<StemJob> {
  const form = new FormData();
  form.append("file", file);
  const res = await fetch(`${STEMS_API}/separate`, { method: "POST", body: form });
  if (!res.ok) throw new Error("Failed to submit stem job");
  return res.json();
}

export async function pollStemJob(id: string): Promise<StemJob> {
  const res = await fetch(`${STEMS_API}/separate/${id}`);
  if (!res.ok) throw new Error("Failed to poll stem job");
  return res.json();
}

export function stemUrl(jobId: string, stem: StemName): string {
  return `${STEMS_API}/separate/${jobId}/stem/${stem}`;
}
