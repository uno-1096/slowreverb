#!/bin/bash
# Run from ~/slowreverb/apps/web

mkdir -p components

# globals.css
cat > app/globals.css << 'EOF'
@import "tailwindcss";

*, *::before, *::after { box-sizing: border-box; }

body {
  background: #0a0a0a;
  color: #e8e8e8;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  margin: 0;
}

:focus-visible {
  outline: 2px solid #a78bfa;
  outline-offset: 2px;
}
EOF

# layout.tsx
cat > app/layout.tsx << 'EOF'
import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "SlowReverb",
  description: "Slow down and reverb your audio files",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
EOF

# page.tsx
cat > app/page.tsx << 'EOF'
import UploadZone from "@/components/UploadZone";

export default function Home() {
  return (
    <main className="min-h-screen flex flex-col items-center justify-center px-4 py-16">
      <h1 className="text-4xl font-bold mb-2 tracking-tight">SlowReverb</h1>
      <p className="text-zinc-400 mb-12 text-sm">
        Upload an audio file. Preview it slowed + reverbed. Export.
      </p>
      <UploadZone />
    </main>
  );
}
EOF

# UploadZone.tsx
cat > components/UploadZone.tsx << 'EOF'
"use client";

import { useCallback, useState } from "react";
import AudioPlayer from "./AudioPlayer";

export default function UploadZone() {
  const [audioFile, setAudioFile] = useState<File | null>(null);
  const [isDragging, setIsDragging] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const ACCEPTED = ["audio/mpeg", "audio/wav", "audio/flac", "audio/aac", "audio/mp4", "audio/ogg"];
  const MAX_MB = 100;

  const handleFile = useCallback((file: File) => {
    setError(null);
    if (!ACCEPTED.includes(file.type)) {
      setError("Unsupported file type. Please upload an MP3, WAV, FLAC, or AAC file.");
      return;
    }
    if (file.size > MAX_MB * 1024 * 1024) {
      setError(`File too large. Maximum size is ${MAX_MB}MB.`);
      return;
    }
    setAudioFile(file);
  }, []);

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setIsDragging(false);
      const file = e.dataTransfer.files[0];
      if (file) handleFile(file);
    },
    [handleFile]
  );

  const onInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) handleFile(file);
  };

  if (audioFile) {
    return (
      <div className="w-full max-w-2xl">
        <div className="flex items-center gap-3 mb-6">
          <div className="flex-1 bg-zinc-900 rounded-lg px-4 py-3 text-sm text-zinc-300 truncate">
            {audioFile.name}
          </div>
          <button
            onClick={() => { setAudioFile(null); setError(null); }}
            className="text-zinc-500 hover:text-zinc-200 text-sm px-3 py-2 rounded-lg hover:bg-zinc-800 transition-colors"
            aria-label="Remove file and start over"
          >
            x remove
          </button>
        </div>
        <AudioPlayer file={audioFile} />
      </div>
    );
  }

  return (
    <div className="w-full max-w-2xl">
      <div
        role="region"
        aria-label="File upload area"
        onDragOver={(e) => { e.preventDefault(); setIsDragging(true); }}
        onDragLeave={() => setIsDragging(false)}
        onDrop={onDrop}
        className={`
          border-2 border-dashed rounded-2xl p-16 text-center transition-colors cursor-pointer
          ${isDragging
            ? "border-violet-500 bg-violet-950/20"
            : "border-zinc-700 hover:border-zinc-500 bg-zinc-900/50"
          }
        `}
        onClick={() => document.getElementById("file-input")?.click()}
        onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") document.getElementById("file-input")?.click(); }}
        tabIndex={0}
      >
        <div className="text-5xl mb-4" aria-hidden="true">🎵</div>
        <p className="text-zinc-300 font-medium mb-1">Drop an audio file here</p>
        <p className="text-zinc-500 text-sm">or click to browse — MP3, WAV, FLAC, AAC up to 100MB</p>
        <input
          id="file-input"
          type="file"
          accept="audio/*"
          className="hidden"
          onChange={onInputChange}
          aria-label="Choose audio file"
        />
      </div>
      {error && (
        <p role="alert" className="mt-3 text-red-400 text-sm text-center">
          {error}
        </p>
      )}
    </div>
  );
}
EOF

# AudioPlayer.tsx
cat > components/AudioPlayer.tsx << 'EOF'
"use client";

import { useEffect, useRef, useState, useCallback } from "react";

interface Props {
  file: File;
}

interface Effects {
  speed: number;
  reverbWet: number;
  reverbDecay: number;
}

export default function AudioPlayer({ file }: Props) {
  const [effects, setEffects] = useState<Effects>({
    speed: 0.75,
    reverbWet: 0.5,
    reverbDecay: 2.0,
  });
  const [isPlaying, setIsPlaying] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);

  const ctxRef = useRef<AudioContext | null>(null);
  const bufferRef = useRef<AudioBuffer | null>(null);
  const sourceRef = useRef<AudioBufferSourceNode | null>(null);
  const startTimeRef = useRef<number>(0);
  const startOffsetRef = useRef<number>(0);
  const rafRef = useRef<number>(0);

  useEffect(() => {
    let cancelled = false;
    setIsLoading(true);
    setError(null);

    const ctx = new AudioContext();
    ctxRef.current = ctx;

    file.arrayBuffer().then((ab) => {
      if (cancelled) return;
      return ctx.decodeAudioData(ab);
    }).then((decoded) => {
      if (cancelled || !decoded) return;
      bufferRef.current = decoded;
      setDuration(decoded.duration);
      setIsLoading(false);
    }).catch((err) => {
      if (cancelled) return;
      console.error("Decode error:", err);
      setError("Could not decode audio. Is this a valid audio file?");
      setIsLoading(false);
    });

    return () => {
      cancelled = true;
      cancelAnimationFrame(rafRef.current);
      ctx.close();
    };
  }, [file]);

  const makeImpulse = useCallback((ctx: AudioContext, decay: number): AudioBuffer => {
    const sampleRate = ctx.sampleRate;
    const length = Math.floor(sampleRate * decay);
    const impulse = ctx.createBuffer(2, length, sampleRate);
    for (let c = 0; c < 2; c++) {
      const ch = impulse.getChannelData(c);
      for (let i = 0; i < length; i++) {
        ch[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / length, 2);
      }
    }
    return impulse;
  }, []);

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
    const buffer = bufferRef.current;
    if (!ctx || !buffer) return;

    if (ctx.state === "suspended") ctx.resume();
    stopPlayback();

    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.playbackRate.value = effects.speed;

    const convolver = ctx.createConvolver();
    convolver.buffer = makeImpulse(ctx, effects.reverbDecay);

    const dryGain = ctx.createGain();
    const wetGain = ctx.createGain();
    dryGain.gain.value = 1 - effects.reverbWet;
    wetGain.gain.value = effects.reverbWet;

    source.connect(dryGain);
    source.connect(convolver);
    convolver.connect(wetGain);
    dryGain.connect(ctx.destination);
    wetGain.connect(ctx.destination);

    sourceRef.current = source;
    startTimeRef.current = ctx.currentTime;
    startOffsetRef.current = offset;

    source.start(0, offset);
    source.onended = () => {
      setIsPlaying(false);
      setCurrentTime(0);
      startOffsetRef.current = 0;
    };

    setIsPlaying(true);

    const tick = () => {
      const ctx2 = ctxRef.current;
      if (!ctx2) return;
      const elapsed = (ctx2.currentTime - startTimeRef.current) * effects.speed;
      setCurrentTime(Math.min(startOffsetRef.current + elapsed, buffer.duration));
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  }, [effects, makeImpulse, stopPlayback]);

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

  const seek = (e: React.ChangeEvent<HTMLInputElement>) => {
    const t = parseFloat(e.target.value);
    startOffsetRef.current = t;
    setCurrentTime(t);
    if (isPlaying) startPlayback(t);
  };

  const fmt = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, "0")}`;
  };

  const updateEffect = (key: keyof Effects, val: number) => {
    setEffects((prev) => ({ ...prev, [key]: val }));
    if (isPlaying) {
      const ctx = ctxRef.current;
      if (ctx) {
        const elapsed = (ctx.currentTime - startTimeRef.current) * effects.speed;
        startOffsetRef.current = Math.min(startOffsetRef.current + elapsed, duration);
      }
      setTimeout(() => startPlayback(startOffsetRef.current), 10);
    }
  };

  if (isLoading) {
    return (
      <div className="bg-zinc-900 rounded-2xl p-8 text-center text-zinc-400 text-sm">
        Decoding audio...
      </div>
    );
  }

  if (error) {
    return (
      <div role="alert" className="bg-red-950/40 border border-red-800 rounded-2xl p-6 text-red-300 text-sm text-center">
        {error}
      </div>
    );
  }

  return (
    <div className="bg-zinc-900 rounded-2xl p-6 space-y-6">
      <div className="flex items-center gap-4">
        <button
          onClick={togglePlay}
          aria-label={isPlaying ? "Pause" : "Play"}
          className="w-12 h-12 rounded-full bg-violet-600 hover:bg-violet-500 flex items-center justify-center text-white text-lg transition-colors flex-shrink-0"
        >
          {isPlaying ? "⏸" : "▶"}
        </button>
        <div className="flex-1 flex items-center gap-3">
          <span className="text-zinc-500 text-xs tabular-nums w-8">{fmt(currentTime)}</span>
          <input
            type="range"
            min={0}
            max={duration}
            step={0.1}
            value={currentTime}
            onChange={seek}
            aria-label="Seek"
            className="flex-1 accent-violet-500"
          />
          <span className="text-zinc-500 text-xs tabular-nums w-8 text-right">{fmt(duration)}</span>
        </div>
      </div>

      <div className="space-y-4 pt-2 border-t border-zinc-800">
        <p className="text-zinc-500 text-xs uppercase tracking-wider">Effects</p>
        <Slider label="Speed" value={effects.speed} min={0.25} max={1.0} step={0.01}
          display={`${Math.round(effects.speed * 100)}%`} onChange={(v) => updateEffect("speed", v)} />
        <Slider label="Reverb mix" value={effects.reverbWet} min={0} max={1} step={0.01}
          display={`${Math.round(effects.reverbWet * 100)}%`} onChange={(v) => updateEffect("reverbWet", v)} />
        <Slider label="Reverb decay" value={effects.reverbDecay} min={0.1} max={5} step={0.1}
          display={`${effects.reverbDecay.toFixed(1)}s`} onChange={(v) => updateEffect("reverbDecay", v)} />
      </div>

      <div className="pt-2 border-t border-zinc-800">
        <button disabled
          className="w-full py-3 rounded-xl bg-zinc-800 text-zinc-500 text-sm cursor-not-allowed">
          Export (coming soon)
        </button>
      </div>
    </div>
  );
}

function Slider({ label, value, min, max, step, display, onChange }: {
  label: string; value: number; min: number; max: number;
  step: number; display: string; onChange: (v: number) => void;
}) {
  return (
    <div className="flex items-center gap-3">
      <label className="text-zinc-300 text-sm w-28 flex-shrink-0">{label}</label>
      <input type="range" min={min} max={max} step={step} value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))}
        aria-label={label} aria-valuetext={display}
        className="flex-1 accent-violet-500" />
      <span className="text-zinc-400 text-sm tabular-nums w-12 text-right" aria-hidden="true">{display}</span>
    </div>
  );
}
EOF

echo "✅ All files written successfully"
