"use client";

import { useState } from "react";
import { separateStems, pollStemJob, stemUrl, StemName } from "@/lib/stems";
import StemPlayer from "./StemPlayer";

interface Props { file: File; }

const STEM_META: Record<StemName, { label: string; emoji: string; color: string }> = {
  vocals: { label: "Vocals",     emoji: "🎤", color: "#a78bfa" },
  drums:  { label: "Drums",      emoji: "🥁", color: "#f472b6" },
  bass:   { label: "Bass",       emoji: "🎸", color: "#34d399" },
  other:  { label: "Instruments",emoji: "🎹", color: "#60a5fa" },
};

type State = "idle" | "uploading" | "processing" | "done" | "error";

export default function StemSeparator({ file }: Props) {
  const [state, setState] = useState<State>("idle");
  const [progress, setProgress] = useState("");
  const [jobId, setJobId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleSeparate = async () => {
    setState("uploading");
    setProgress("Uploading to Demucs...");
    setError(null);
    try {
      const job = await separateStems(file);
      setJobId(job.id);
      setState("processing");
      setProgress("Separating stems with AI (15-30 seconds)...");

      let current = job;
      let attempts = 0;
      while (current.status === "pending" || current.status === "processing") {
        await new Promise(r => setTimeout(r, 2000));
        current = await pollStemJob(job.id);
        attempts++;
        if (attempts > 60) throw new Error("Timed out");
      }

      if (current.status === "failed") throw new Error(current.error ?? "Separation failed");

      setState("done");
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Failed";
      setError(msg);
      setState("error");
    }
  };

  if (state === "idle" || state === "error") {
    return (
      <div className="pt-3 border-t border-zinc-800 space-y-2">
        <div className="flex items-center gap-2">
          <p className="text-zinc-500 text-xs uppercase tracking-wider flex-1">Stem Separation</p>
          <span className="text-zinc-600 text-xs">powered by Demucs</span>
        </div>
        {error && <p className="text-red-400 text-xs">{error}</p>}
        <button onClick={handleSeparate}
          className="w-full py-2.5 rounded-xl bg-zinc-800 hover:bg-zinc-700 border border-zinc-700 hover:border-zinc-500 text-zinc-300 text-sm transition-colors">
          🎚 Separate Stems (vocals / drums / bass / other)
        </button>
      </div>
    );
  }

  if (state === "uploading" || state === "processing") {
    return (
      <div className="pt-3 border-t border-zinc-800 space-y-3">
        <p className="text-zinc-500 text-xs uppercase tracking-wider">Stem Separation</p>
        <div className="bg-zinc-800 rounded-xl p-4 space-y-2">
          <div className="flex items-center gap-3">
            <div className="w-4 h-4 border-2 border-violet-500 border-t-transparent rounded-full animate-spin" />
            <p className="text-zinc-300 text-sm">{progress}</p>
          </div>
          <p className="text-zinc-500 text-xs">Your RTX 3060 Ti is processing this locally</p>
        </div>
      </div>
    );
  }

  if (state === "done" && jobId) {
    return (
      <div className="pt-3 border-t border-zinc-800 space-y-3">
        <p className="text-zinc-500 text-xs uppercase tracking-wider">Stems — individual controls</p>
        <div className="grid grid-cols-1 gap-3">
          {(Object.keys(STEM_META) as StemName[]).map(stem => (
            <StemPlayer
              key={stem}
              jobId={jobId}
              stem={stem}
              url={stemUrl(jobId, stem)}
              label={STEM_META[stem].label}
              emoji={STEM_META[stem].emoji}
              color={STEM_META[stem].color}
            />
          ))}
        </div>
      </div>
    );
  }

  return null;
}
