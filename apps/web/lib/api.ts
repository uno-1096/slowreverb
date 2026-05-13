const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8081";

export interface Job {
  id: string;
  file_name: string;
  status: "pending" | "processing" | "done" | "failed";
  speed: number;
  reverb_wet: number;
  reverb_decay: number;
  format: string;
  error?: string;
}

export async function submitJob(
  file: File,
  speed: number,
  reverbWet: number,
  reverbDecay: number,
  format: "wav" | "mp3" = "wav"
): Promise<Job> {
  const form = new FormData();
  form.append("file", file);
  form.append("speed", String(speed));
  form.append("reverb_wet", String(reverbWet));
  form.append("reverb_decay", String(reverbDecay));
  form.append("format", format);

  const res = await fetch(`${API_BASE}/api/v1/jobs`, {
    method: "POST",
    body: form,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Failed to submit job: ${text}`);
  }

  return res.json();
}

export async function pollJob(id: string): Promise<Job> {
  const res = await fetch(`${API_BASE}/api/v1/jobs/${id}`);
  if (!res.ok) throw new Error("Failed to poll job");
  return res.json();
}

export function downloadUrl(id: string): string {
  return `${API_BASE}/api/v1/jobs/${id}/download`;
}
