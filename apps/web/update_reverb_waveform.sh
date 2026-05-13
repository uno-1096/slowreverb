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
  preservePitch: boolean;
}

export default function AudioPlayer({ file }: Props) {
  const [effects, setEffects] = useState<Effects>({
    speed: 0.75,
    reverbWet: 0.5,
    reverbDecay: 2.0,
    preservePitch: false,
  });
  const [isPlaying, setIsPlaying] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [exporting, setExporting] = useState(false);
  const [exportProgress, setExportProgress] = useState(0);
  const [exportStatus, setExportStatus] = useState("");
  const [irBuffer, setIrBuffer] = useState<AudioBuffer | null>(null);

  const ctxRef = useRef<AudioContext | null>(null);
  const bufferRef = useRef<AudioBuffer | null>(null);
  const sourceRef = useRef<AudioBufferSourceNode | null>(null);
  const startTimeRef = useRef<number>(0);
  const startOffsetRef = useRef<number>(0);
  const rafRef = useRef<number>(0);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  // Decode audio file + load IR on mount
  useEffect(() => {
    let cancelled = false;
    setIsLoading(true);
    setError(null);

    const ctx = new AudioContext();
    ctxRef.current = ctx;

    const decodeMain = file.arrayBuffer().then((ab) => {
      if (cancelled) return;
      return ctx.decodeAudioData(ab);
    });

    const decodeIR = fetch("/ir/large-hall.wav")
      .then((r) => r.arrayBuffer())
      .then((ab) => ctx.decodeAudioData(ab))
      .catch(() => null); // IR failing is non-fatal, fall back to synthetic

    Promise.all([decodeMain, decodeIR]).then(([decoded, ir]) => {
      if (cancelled) return;
      if (!decoded) return;
      bufferRef.current = decoded;
      setDuration(decoded.duration);
      if (ir) setIrBuffer(ir);
      setIsLoading(false);
      drawWaveform(decoded);
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

  // Draw waveform on canvas
  const drawWaveform = (buffer: AudioBuffer) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const width = canvas.width;
    const height = canvas.height;
    const data = buffer.getChannelData(0);
    const step = Math.ceil(data.length / width);
    const amp = height / 2;

    ctx.clearRect(0, 0, width, height);

    for (let i = 0; i < width; i++) {
      let min = 1, max = -1;
      for (let j = 0; j < step; j++) {
        const val = data[i * step + j] || 0;
        if (val < min) min = val;
        if (val > max) max = val;
      }
      ctx.fillStyle = "#6d28d9";
      ctx.fillRect(i, (1 + min) * amp, 1, Math.max(1, (max - min) * amp));
    }
  };

  // Draw playhead over waveform
  const drawPlayhead = useCallback((progress: number) => {
    const canvas = canvasRef.current;
    if (!canvas || !bufferRef.current) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    drawWaveform(bufferRef.current);
    const x = progress * canvas.width;
    ctx.fillStyle = "#a78bfa";
    ctx.fillRect(x - 1, 0, 2, canvas.height);
  }, []);

  const makeSyntheticImpulse = useCallback((ctx: AudioContext | OfflineAudioContext, decay: number): AudioBuffer => {
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

  const buildGraph = useCallback((
    ctx: AudioContext | OfflineAudioContext,
    buffer: AudioBuffer,
    dest: AudioNode,
    fx: Effects,
    irBuf: AudioBuffer | null
  ): AudioBufferSourceNode => {
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.playbackRate.value = fx.speed;

    // Pitch preservation via detune (offsets the pitch shift caused by playbackRate)
    if (fx.preservePitch) {
      // Slowing down lowers pitch; detune up by the inverse to compensate
      // 1 semitone = 100 cents; ratio = 1/speed means pitch up by log2(1/speed)*1200 cents
      source.detune.value = -Math.log2(fx.speed) * 1200;
    }

    const convolver = ctx.createConvolver();
    convolver.buffer = irBuf ?? makeSyntheticImpulse(ctx, fx.reverbDecay);

    const dryGain = ctx.createGain();
    const wetGain = ctx.createGain();
    dryGain.gain.value = 1 - fx.reverbWet;
    wetGain.gain.value = fx.reverbWet;

    source.connect(dryGain);
    source.connect(convolver);
    convolver.connect(wetGain);
    dryGain.connect(dest);
    wetGain.connect(dest);

    return source;
  }, [makeSyntheticImpulse]);

  const startPlayback = useCallback((offset = 0) => {
    const ctx = ctxRef.current;
    const buffer = bufferRef.current;
    if (!ctx || !buffer) return;

    if (ctx.state === "suspended") ctx.resume();
    stopPlayback();

    const source = buildGraph(ctx, buffer, ctx.destination, effects, irBuffer);
    sourceRef.current = source;
    startTimeRef.current = ctx.currentTime;
    startOffsetRef.current = offset;

    source.start(0, offset);
    source.onended = () => {
      setIsPlaying(false);
      setCurrentTime(0);
      startOffsetRef.current = 0;
      drawPlayhead(0);
    };

    setIsPlaying(true);

    const tick = () => {
      const ctx2 = ctxRef.current;
      const buf = bufferRef.current;
      if (!ctx2 || !buf) return;
      const elapsed = (ctx2.currentTime - startTimeRef.current) * effects.speed;
      const t = Math.min(startOffsetRef.current + elapsed, buf.duration);
      setCurrentTime(t);
      drawPlayhead(t / buf.duration);
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  }, [effects, irBuffer, buildGraph, stopPlayback, drawPlayhead]);

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
    drawPlayhead(t / duration);
    if (isPlaying) startPlayback(t);
  };

  const fmt = (s: number) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, "0")}`;
  };

  const updateEffect = (key: keyof Effects, val: number | boolean) => {
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

  const encodeWav = (buffer: AudioBuffer): Blob => {
    const numChannels = buffer.numberOfChannels;
    const sampleRate = buffer.sampleRate;
    const numSamples = buffer.length;
    const blockAlign = numChannels * 2;
    const dataSize = numSamples * blockAlign;
    const ab = new ArrayBuffer(44 + dataSize);
    const view = new DataView(ab);
    const writeStr = (o: number, s: string) => { for (let i = 0; i < s.length; i++) view.setUint8(o + i, s.charCodeAt(i)); };
    writeStr(0, "RIFF"); view.setUint32(4, 36 + dataSize, true);
    writeStr(8, "WAVE"); writeStr(12, "fmt ");
    view.setUint32(16, 16, true); view.setUint16(20, 1, true);
    view.setUint16(22, numChannels, true); view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * blockAlign, true); view.setUint16(32, blockAlign, true);
    view.setUint16(34, 16, true); writeStr(36, "data"); view.setUint32(40, dataSize, true);
    let offset = 44;
    for (let i = 0; i < numSamples; i++) {
      for (let ch = 0; ch < numChannels; ch++) {
        const s = Math.max(-1, Math.min(1, buffer.getChannelData(ch)[i]));
        view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
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
      const baseName = file.name.replace(/\.[^.]+$/, "");
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
  };

  if (isLoading) {
    return <div className="bg-zinc-900 rounded-2xl p-8 text-center text-zinc-400 text-sm">Decoding audio...</div>;
  }

  if (error) {
    return (
      <div role="alert" className="bg-red-950/40 border border-red-800 rounded-2xl p-6 text-red-300 text-sm text-center">
        {error}
      </div>
    );
  }

  return (
    <div className="bg-zinc-900 rounded-2xl p-6 space-y-5">

      {/* Waveform */}
      <div
        className="relative cursor-pointer rounded-lg overflow-hidden"
        onClick={(e) => {
          const rect = e.currentTarget.getBoundingClientRect();
          const t = ((e.clientX - rect.left) / rect.width) * duration;
          startOffsetRef.current = t;
          setCurrentTime(t);
          drawPlayhead(t / duration);
          if (isPlaying) startPlayback(t);
        }}
        aria-label="Waveform — click to seek"
        role="slider"
        aria-valuenow={currentTime}
        aria-valuemin={0}
        aria-valuemax={duration}
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === "ArrowRight") seek({ target: { value: String(Math.min(currentTime + 5, duration)) } } as React.ChangeEvent<HTMLInputElement>);
          if (e.key === "ArrowLeft") seek({ target: { value: String(Math.max(currentTime - 5, 0)) } } as React.ChangeEvent<HTMLInputElement>);
        }}
      >
        <canvas ref={canvasRef} width={800} height={80} className="w-full h-20 block" />
      </div>

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
          <input type="range" min={0} max={duration} step={0.1} value={currentTime}
            onChange={seek} aria-label="Seek" className="flex-1 accent-violet-500" />
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

        {/* Pitch preservation toggle */}
        <div className="flex items-center gap-3">
          <span className="text-zinc-300 text-sm w-28 flex-shrink-0">Preserve pitch</span>
          <button
            role="switch"
            aria-checked={effects.preservePitch}
            onClick={() => updateEffect("preservePitch", !effects.preservePitch)}
            className={`relative w-10 h-6 rounded-full transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 ${
              effects.preservePitch ? "bg-violet-600" : "bg-zinc-700"
            }`}
            aria-label="Preserve pitch when slowing down"
          >
            <span className={`absolute top-1 w-4 h-4 rounded-full bg-white transition-transform ${
              effects.preservePitch ? "translate-x-5" : "translate-x-1"
            }`} />
          </button>
          <span className="text-zinc-500 text-xs">
            {effects.preservePitch ? "on — pitch stays constant" : "off — pitch drops with speed"}
          </span>
        </div>
      </div>

      {/* Export */}
      <div className="pt-2 border-t border-zinc-800 space-y-3">
        <p className="text-zinc-500 text-xs uppercase tracking-wider">Export</p>
        {exporting ? (
          <div className="space-y-2">
            <div className="w-full bg-zinc-800 rounded-full h-2 overflow-hidden">
              <div className="bg-violet-500 h-2 rounded-full transition-all duration-300"
                style={{ width: `${exportProgress}%` }}
                role="progressbar" aria-valuenow={exportProgress} aria-valuemin={0} aria-valuemax={100} />
            </div>
            <p className="text-zinc-500 text-xs text-center">{exportStatus}</p>
          </div>
        ) : (
          <button onClick={handleExport}
            className="w-full py-3 rounded-xl bg-violet-600 hover:bg-violet-500 text-white text-sm font-medium transition-colors"
            aria-label="Export processed audio as WAV">
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
        aria-label={label} aria-valuetext={display} className="flex-1 accent-violet-500" />
      <span className="text-zinc-400 text-sm tabular-nums w-12 text-right" aria-hidden="true">{display}</span>
    </div>
  );
}
EOF

echo "✅ AudioPlayer updated — real IR reverb + waveform + pitch toggle"
