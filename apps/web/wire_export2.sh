#!/bin/bash
# Run from ~/slowreverb/apps/web

mkdir -p lib

cat > lib/api.ts << 'EOF'
const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8081";

export interface Job {
  id: string;
  file_name: string;
  status: "pending" | "processing" | "done" | "failed";
  speed: number;
  reverb_wet: number;
  reverb_decay: number;
  error?: string;
}

export async function submitJob(
  file: File,
  speed: number,
  reverbWet: number,
  reverbDecay: number
): Promise<Job> {
  const form = new FormData();
  form.append("file", file);
  form.append("speed", String(speed));
  form.append("reverb_wet", String(reverbWet));
  form.append("reverb_decay", String(reverbDecay));

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
EOF

# Now update just the export section of AudioPlayer.tsx
python3 << 'PYEOF'
with open('components/AudioPlayer.tsx', 'r') as f:
    content = f.read()

# Add import at top
old_import = '"use client";\n\nimport { useEffect, useRef, useState, useCallback } from "react";'
new_import = '"use client";\n\nimport { useEffect, useRef, useState, useCallback } from "react";\nimport { submitJob, pollJob, downloadUrl } from "@/lib/api";'
content = content.replace(old_import, new_import)

# Replace handleExport function
old_export = '''  const handleExport = async () => {
    const buffer = bufferRef.current;
    if (!buffer) return;
    setExporting(true);
    setExportProgress(5);
    setExportStatus("Setting up...");
    try {
      const outputLength = Math.ceil((buffer.duration / effects.speed) * buffer.sampleRate);
      const offlineCtx = new OfflineAudioContext(buffer.numberOfChannels, outputLength, buffer.sampleRate);
      setExportProgress(15);
      setExportStatus("Building audio graph...");

      const source = buildGraph(offlineCtx, buffer, offlineCtx.destination, effects, irBuffer);
      source.start(0);

      setExportProgress(20);
      setExportStatus("Rendering audio (this may take a moment)...");
      const rendered = await offlineCtx.startRendering();

      setExportProgress(85);
      setExportStatus("Encoding WAV...");
      const blob = encodeWav(rendered);

      setExportProgress(95);
      const baseName = file.name.replace(/\\.[^.]+$/, "");
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `${baseName}_slowed_reverb.wav`;
      a.click();
      URL.revokeObjectURL(url);

      setExportProgress(100);
      setExportStatus("Done!");
      setTimeout(() => { setExporting(false); setExportProgress(0); setExportStatus(""); }, 1500);
    } catch (err) {
      console.error("Export error:", err);
      setExporting(false);
      setExportProgress(0);
      setExportStatus("");
    }
  };'''

new_export = '''  const handleExport = async () => {
    setExporting(true);
    setExportProgress(5);
    setExportStatus("Uploading file...");
    try {
      // Submit job to Go API
      const job = await submitJob(file, effects.speed, effects.reverbWet, effects.reverbDecay);
      setExportProgress(20);
      setExportStatus("Processing with FFmpeg...");

      // Poll until done
      let current = job;
      let attempts = 0;
      while (current.status === "pending" || current.status === "processing") {
        await new Promise((r) => setTimeout(r, 1000));
        current = await pollJob(job.id);
        attempts++;
        // Progress from 20 to 85 while processing
        const progress = Math.min(20 + attempts * 5, 85);
        setExportProgress(progress);
        if (attempts > 120) throw new Error("Job timed out");
      }

      if (current.status === "failed") {
        throw new Error(current.error ?? "Job failed");
      }

      setExportProgress(90);
      setExportStatus("Downloading...");

      // Trigger download
      const a = document.createElement("a");
      a.href = downloadUrl(job.id);
      a.download = file.name.replace(/\\.[^.]+$/, "") + "_slowed_reverb.wav";
      a.click();

      setExportProgress(100);
      setExportStatus("Done!");
      setTimeout(() => { setExporting(false); setExportProgress(0); setExportStatus(""); }, 1500);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Export failed";
      console.error("Export error:", msg);
      setExportStatus("Error: " + msg);
      setTimeout(() => { setExporting(false); setExportProgress(0); setExportStatus(""); }, 3000);
    }
  };'''

content = content.replace(old_export, new_export)

with open('components/AudioPlayer.tsx', 'w') as f:
    f.write(content)

print("✅ AudioPlayer export wired to Go API")
PYEOF

echo "✅ All done"
