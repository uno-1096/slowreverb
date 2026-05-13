#!/bin/bash
# Run from ~/slowreverb/apps/web

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

type ExportFormat = "wav" | "mp3";

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
  const [exporting, setExporting] = useState(false);
  const [exportProgress, setExportProgress] = useState(0);
  const [exportFormat, setExportFormat] = useState<ExportFormat>("wav");

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

  const makeImpulse = useCallback((ctx: AudioContext | OfflineAudioContext, decay: number): AudioBuffer => {
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

  // Encode AudioBuffer to WAV bytes
  const encodeWav = (buffer: AudioBuffer): Blob => {
    const numChannels = buffer.numberOfChannels;
    const sampleRate = buffer.sampleRate;
    const numSamples = buffer.length;
    const bytesPerSample = 2;
    const blockAlign = numChannels * bytesPerSample;
    const byteRate = sampleRate * blockAlign;
    const dataSize = numSamples * blockAlign;
    const headerSize = 44;

    const ab = new ArrayBuffer(headerSize + dataSize);
    const view = new DataView(ab);

    const writeStr = (offset: number, s: string) => {
      for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
    };

    writeStr(0, "RIFF");
    view.setUint32(4, 36 + dataSize, true);
    writeStr(8, "WAVE");
    writeStr(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); // PCM
    view.setUint16(22, numChannels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, byteRate, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, 16, true); // bits per sample
    writeStr(36, "data");
    view.setUint32(40, dataSize, true);

    // Interleave channels
    let offset = 44;
    for (let i = 0; i < numSamples; i++) {
      for (let ch = 0; ch < numChannels; ch++) {
        const sample = Math.max(-1, Math.min(1, buffer.getChannelData(ch)[i]));
        view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
        offset += 2;
      }
    }

    return new Blob([ab], { type: "audio/wav" });
  };

  const handleExport = async () => {
    const buffer = bufferRef.current;
    if (!buffer) return;

    setExporting(true);
    setExportProgress(5);

    try {
      // The output duration is longer because we slowed down
      const outputDuration = buffer.duration / effects.speed;
      const sampleRate = buffer.sampleRate;
      const outputLength = Math.ceil(outputDuration * sampleRate);

      setExportProgress(10);

      // OfflineAudioContext renders faster than real-time
      const offlineCtx = new OfflineAudioContext(
        buffer.numberOfChannels,
        outputLength,
        sampleRate
      );

      const source = offlineCtx.createBufferSource();
      source.buffer = buffer;
      source.playbackRate.value = effects.speed;

      const convolver = offlineCtx.createConvolver();
      convolver.buffer = makeImpulse(offlineCtx, effects.reverbDecay);

      const dryGain = offlineCtx.createGain();
      const wetGain = offlineCtx.createGain();
      dryGain.gain.value = 1 - effects.reverbWet;
      wetGain.gain.value = effects.reverbWet;

      source.connect(dryGain);
      source.connect(convolver);
      convolver.connect(wetGain);
      dryGain.connect(offlineCtx.destination);
      wetGain.connect(offlineCtx.destination);

      source.start(0);

      setExportProgress(20);

      // Render — this is where the heavy work happens
      const rendered = await offlineCtx.startRendering();

      setExportProgress(85);

      const blob = encodeWav(rendered);

      setExportProgress(95);

      // Trigger download
      const baseName = file.name.replace(/\.[^.]+$/, "");
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `${baseName}_slowed_reverb.wav`;
      a.click();
      URL.revokeObjectURL(url);

      setExportProgress(100);
      setTimeout(() => {
        setExporting(false);
        setExportProgress(0);
      }, 1500);

    } catch (err) {
      console.error("Export error:", err);
      setExporting(false);
      setExportProgress(0);
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
      {/* Transport */}
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

      {/* Effects */}
      <div className="space-y-4 pt-2 border-t border-zinc-800">
        <p className="text-zinc-500 text-xs uppercase tracking-wider">Effects</p>
        <Slider label="Speed" value={effects.speed} min={0.25} max={1.0} step={0.01}
          display={`${Math.round(effects.speed * 100)}%`} onChange={(v) => updateEffect("speed", v)} />
        <Slider label="Reverb mix" value={effects.reverbWet} min={0} max={1} step={0.01}
          display={`${Math.round(effects.reverbWet * 100)}%`} onChange={(v) => updateEffect("reverbWet", v)} />
        <Slider label="Reverb decay" value={effects.reverbDecay} min={0.1} max={5} step={0.1}
          display={`${effects.reverbDecay.toFixed(1)}s`} onChange={(v) => updateEffect("reverbDecay", v)} />
      </div>

      {/* Export */}
      <div className="pt-2 border-t border-zinc-800 space-y-3">
        <div className="flex items-center gap-3">
          <p className="text-zinc-500 text-xs uppercase tracking-wider flex-1">Export</p>
          <select
            value={exportFormat}
            onChange={(e) => setExportFormat(e.target.value as ExportFormat)}
            disabled={exporting}
            aria-label="Export format"
            className="bg-zinc-800 text-zinc-300 text-xs rounded-lg px-2 py-1 border border-zinc-700 focus:outline-none focus:border-violet-500"
          >
            <option value="wav">WAV</option>
          </select>
        </div>

        {exporting ? (
          <div className="space-y-2">
            <div className="w-full bg-zinc-800 rounded-full h-2 overflow-hidden">
              <div
                className="bg-violet-500 h-2 rounded-full transition-all duration-300"
                style={{ width: `${exportProgress}%` }}
                role="progressbar"
                aria-valuenow={exportProgress}
                aria-valuemin={0}
                aria-valuemax={100}
                aria-label="Export progress"
              />
            </div>
            <p className="text-zinc-500 text-xs text-center">
              {exportProgress < 20 ? "Setting up..." :
               exportProgress < 85 ? "Rendering audio..." :
               exportProgress < 100 ? "Encoding WAV..." : "Done!"}
            </p>
          </div>
        ) : (
          <button
            onClick={handleExport}
            className="w-full py-3 rounded-xl bg-violet-600 hover:bg-violet-500 text-white text-sm font-medium transition-colors"
            aria-label="Export processed audio"
          >
            Export WAV
          </button>
        )}
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

echo "✅ AudioPlayer.tsx updated with export"
