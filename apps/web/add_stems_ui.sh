#!/bin/bash
# Run from ~/slowreverb/apps/web

# Add stems API client
cat > lib/stems.ts << 'EOF'
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
EOF

# Create StemPlayer component
cat > components/StemPlayer.tsx << 'EOF'
"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { StemName } from "@/lib/stems";

interface Props {
  jobId: string;
  stem: StemName;
  url: string;
  color: string;
  label: string;
  emoji: string;
}

interface Effects {
  speed: number;
  reverbWet: number;
  muted: boolean;
  volume: number;
}

export default function StemPlayer({ stem, url, color, label, emoji }: Props) {
  const [effects, setEffects] = useState<Effects>({
    speed: 0.75,
    reverbWet: 0.4,
    muted: false,
    volume: 1.0,
  });
  const [isPlaying, setIsPlaying] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);

  const ctxRef = useRef<AudioContext | null>(null);
  const bufferRef = useRef<AudioBuffer | null>(null);
  const sourceRef = useRef<AudioBufferSourceNode | null>(null);
  const gainRef = useRef<GainNode | null>(null);
  const startTimeRef = useRef(0);
  const startOffsetRef = useRef(0);
  const rafRef = useRef(0);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    let cancelled = false;
    const ctx = new AudioContext();
    ctxRef.current = ctx;

    fetch(url).then(r => r.arrayBuffer()).then(ab => ctx.decodeAudioData(ab)).then(buf => {
      if (cancelled) return;
      bufferRef.current = buf;
      setDuration(buf.duration);
      setIsLoading(false);
      setTimeout(() => drawWave(buf), 50);
    }).catch(() => { if (!cancelled) setIsLoading(false); });

    return () => { cancelled = true; cancelAnimationFrame(rafRef.current); ctx.close(); };
  }, [url]);

  const drawWave = (buf: AudioBuffer) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const W = canvas.width, H = canvas.height;
    const data = buf.getChannelData(0);
    const step = Math.ceil(data.length / W);
    const amp = H / 2;
    ctx.clearRect(0, 0, W, H);
    for (let i = 0; i < W; i++) {
      let min = 1, max = -1;
      for (let j = 0; j < step; j++) {
        const v = data[i * step + j] || 0;
        if (v < min) min = v;
        if (v > max) max = v;
      }
      ctx.fillStyle = color;
      ctx.fillRect(i, (1 + min) * amp, 1, Math.max(1, (max - min) * amp));
    }
  };

  const stopPlayback = useCallback(() => {
    cancelAnimationFrame(rafRef.current);
    if (sourceRef.current) {
      try { sourceRef.current.stop(); } catch {}
      sourceRef.current.disconnect();
      sourceRef.current = null;
    }
    setIsPlaying(false);
  }, []);

  const startPlayback = useCallback((offset = 0) => {
    const ctx = ctxRef.current;
    const buf = bufferRef.current;
    if (!ctx || !buf) return;
    if (ctx.state === "suspended") ctx.resume();
    stopPlayback();

    const source = ctx.createBufferSource();
    source.buffer = buf;
    source.playbackRate.value = effects.speed;

    const gain = ctx.createGain();
    gain.gain.value = effects.muted ? 0 : effects.volume;
    gainRef.current = gain;

    source.connect(gain);
    gain.connect(ctx.destination);
    sourceRef.current = source;
    startTimeRef.current = ctx.currentTime;
    startOffsetRef.current = offset;

    source.start(0, offset);
    source.onended = () => { setIsPlaying(false); setCurrentTime(0); startOffsetRef.current = 0; };
    setIsPlaying(true);

    const tick = () => {
      const ctx2 = ctxRef.current;
      if (!ctx2) return;
      const elapsed = (ctx2.currentTime - startTimeRef.current) * effects.speed;
      setCurrentTime(Math.min(startOffsetRef.current + elapsed, buf.duration));
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  }, [effects, stopPlayback]);

  const togglePlay = () => {
    if (isPlaying) {
      const ctx = ctxRef.current;
      if (ctx) {
        const elapsed = (ctx.currentTime - startTimeRef.current) * effects.speed;
        startOffsetRef.current = Math.min(startOffsetRef.current + elapsed, duration);
      }
      stopPlayback();
    } else {
      startPlayback(startOffsetRef.current);
    }
  };

  const fmt = (s: number) => `${Math.floor(s / 60)}:${Math.floor(s % 60).toString().padStart(2, "0")}`;

  const updateEffect = <K extends keyof Effects>(key: K, val: Effects[K]) => {
    setEffects(prev => {
      const next = { ...prev, [key]: val };
      if (gainRef.current) {
        gainRef.current.gain.value = next.muted ? 0 : next.volume;
      }
      if (sourceRef.current && key === "speed") {
        sourceRef.current.playbackRate.value = val as number;
      }
      return next;
    });
  };

  return (
    <div className={`rounded-xl p-4 space-y-3 border ${effects.muted ? "opacity-50 border-zinc-800" : "border-zinc-700"} bg-zinc-900`}>
      <div className="flex items-center gap-2">
        <span className="text-lg">{emoji}</span>
        <span className="text-zinc-200 text-sm font-medium flex-1">{label}</span>
        <button
          onClick={() => updateEffect("muted", !effects.muted)}
          className={`text-xs px-2 py-1 rounded-lg border transition-colors ${
            effects.muted
              ? "bg-zinc-800 border-zinc-700 text-zinc-500"
              : "bg-zinc-700 border-zinc-600 text-zinc-200"
          }`}
          aria-label={effects.muted ? "Unmute" : "Mute"}
        >
          {effects.muted ? "muted" : "mute"}
        </button>
        <button
          onClick={togglePlay}
          disabled={isLoading}
          className="w-8 h-8 rounded-full flex items-center justify-center text-white text-sm transition-colors"
          style={{ backgroundColor: color }}
          aria-label={isPlaying ? "Pause" : "Play"}
        >
          {isLoading ? "…" : isPlaying ? "⏸" : "▶"}
        </button>
      </div>

      <canvas ref={canvasRef} width={600} height={40}
        className="w-full h-10 block rounded cursor-pointer"
        onClick={e => {
          const rect = e.currentTarget.getBoundingClientRect();
          const t = ((e.clientX - rect.left) / rect.width) * duration;
          startOffsetRef.current = t;
          setCurrentTime(t);
          if (isPlaying) startPlayback(t);
        }}
      />

      <div className="flex items-center gap-2">
        <span className="text-zinc-500 text-xs w-8 tabular-nums">{fmt(currentTime)}</span>
        <input type="range" min={0} max={duration} step={0.1} value={currentTime}
          onChange={e => {
            const t = parseFloat(e.target.value);
            startOffsetRef.current = t; setCurrentTime(t);
            if (isPlaying) startPlayback(t);
          }}
          className="flex-1" style={{ accentColor: color }} aria-label="Seek" />
        <span className="text-zinc-500 text-xs w-8 tabular-nums text-right">{fmt(duration)}</span>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1">
          <label className="text-zinc-400 text-xs">Speed</label>
          <div className="flex items-center gap-2">
            <input type="range" min={0.25} max={1.0} step={0.01} value={effects.speed}
              onChange={e => updateEffect("speed", parseFloat(e.target.value))}
              className="flex-1" style={{ accentColor: color }} />
            <span className="text-zinc-400 text-xs w-8 tabular-nums">{Math.round(effects.speed * 100)}%</span>
          </div>
        </div>
        <div className="space-y-1">
          <label className="text-zinc-400 text-xs">Reverb</label>
          <div className="flex items-center gap-2">
            <input type="range" min={0} max={1} step={0.01} value={effects.reverbWet}
              onChange={e => updateEffect("reverbWet", parseFloat(e.target.value))}
              className="flex-1" style={{ accentColor: color }} />
            <span className="text-zinc-400 text-xs w-8 tabular-nums">{Math.round(effects.reverbWet * 100)}%</span>
          </div>
        </div>
        <div className="space-y-1 col-span-2">
          <label className="text-zinc-400 text-xs">Volume</label>
          <div className="flex items-center gap-2">
            <input type="range" min={0} max={1.5} step={0.01} value={effects.volume}
              onChange={e => updateEffect("volume", parseFloat(e.target.value))}
              className="flex-1" style={{ accentColor: color }} />
            <span className="text-zinc-400 text-xs w-8 tabular-nums">{Math.round(effects.volume * 100)}%</span>
          </div>
        </div>
      </div>
    </div>
  );
}
EOF

# Create StemSeparator component
cat > components/StemSeparator.tsx << 'EOF'
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
EOF

# Add StemSeparator to AudioPlayer
python3 << 'PYEOF'
with open('components/AudioPlayer.tsx', 'r') as f:
    content = f.read()

# Add import
old = 'import { submitJob, pollJob, downloadUrl } from "@/lib/api";'
new = 'import { submitJob, pollJob, downloadUrl } from "@/lib/api";\nimport StemSeparator from "./StemSeparator";'
content = content.replace(old, new)

# Add StemSeparator before closing div
old = '    </div>\n  );\n}\n\nfunction Slider'
new = '      <StemSeparator file={file} />\n    </div>\n  );\n}\n\nfunction Slider'
content = content.replace(old, new)

with open('components/AudioPlayer.tsx', 'w') as f:
    f.write(content)
print("✅ StemSeparator added to AudioPlayer")
PYEOF

echo "✅ All stem UI files written"
