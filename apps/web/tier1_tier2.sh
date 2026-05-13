#!/bin/bash
# Run from ~/slowreverb/apps/web

python3 << 'PYEOF'
content = r'''
"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { submitJob, pollJob, downloadUrl } from "@/lib/api";

interface Props { file: File; }

interface Effects {
  speed: number;
  reverbWet: number;
  reverbDecay: number;
  preservePitch: boolean;
  reverbPreset: string;
}

interface LoopRegion { start: number; end: number; }

const PRESETS = [
  { id: "large-hall", label: "Large Hall", file: "/ir/large-hall.wav" },
  { id: "small-room", label: "Small Room", file: "/ir/small-room.wav" },
  { id: "plate",      label: "Plate",      file: "/ir/plate.wav" },
  { id: "cathedral",  label: "Cathedral",  file: "/ir/cathedral.wav" },
  { id: "synthetic",  label: "Synthetic",  file: null },
];

function detectBPM(buffer: AudioBuffer): number {
  const data = buffer.getChannelData(0);
  const sr = buffer.sampleRate;
  const windowSize = Math.floor(sr * 0.01);
  const energies: number[] = [];
  for (let i = 0; i < data.length - windowSize; i += windowSize) {
    let e = 0;
    for (let j = 0; j < windowSize; j++) e += data[i + j] ** 2;
    energies.push(e / windowSize);
  }
  const mean = energies.reduce((a, b) => a + b, 0) / energies.length;
  const beats: number[] = [];
  for (let i = 1; i < energies.length - 1; i++) {
    if (energies[i] > mean * 1.5 && energies[i] > energies[i - 1] && energies[i] > energies[i + 1]) {
      beats.push(i);
    }
  }
  if (beats.length < 2) return 120;
  const intervals: number[] = [];
  for (let i = 1; i < beats.length; i++) {
    intervals.push((beats[i] - beats[i - 1]) * windowSize / sr);
  }
  const avgInterval = intervals.sort((a, b) => a - b)[Math.floor(intervals.length / 2)];
  return Math.round(60 / avgInterval);
}

export default function AudioPlayer({ file }: Props) {
  const [effects, setEffects] = useState<Effects>({
    speed: 0.75,
    reverbWet: 0.5,
    reverbDecay: 2.0,
    preservePitch: false,
    reverbPreset: "large-hall",
  });
  const [isPlaying, setIsPlaying] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [exporting, setExporting] = useState(false);
  const [exportProgress, setExportProgress] = useState(0);
  const [exportStatus, setExportStatus] = useState("");
  const [exportFormat, setExportFormat] = useState<"wav" | "mp3">("mp3");
  const [irBuffers, setIrBuffers] = useState<Record<string, AudioBuffer>>({});
  const [detectedBPM, setDetectedBPM] = useState<number | null>(null);
  const [targetBPM, setTargetBPM] = useState<number | null>(null);
  const [loopRegion, setLoopRegion] = useState<LoopRegion | null>(null);
  const [isDraggingLoop, setIsDraggingLoop] = useState(false);
  const [loopDragStart, setLoopDragStart] = useState<number | null>(null);
  const [zoom, setZoom] = useState(1);
  const [zoomOffset, setZoomOffset] = useState(0);

  const ctxRef = useRef<AudioContext | null>(null);
  const bufferRef = useRef<AudioBuffer | null>(null);
  const sourceRef = useRef<AudioBufferSourceNode | null>(null);
  const startTimeRef = useRef<number>(0);
  const startOffsetRef = useRef<number>(0);
  const rafRef = useRef<number>(0);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const loopRef = useRef<LoopRegion | null>(null);
  const effectsRef = useRef(effects);
  effectsRef.current = effects;
  loopRef.current = loopRegion;

  // Load audio + all IR files
  useEffect(() => {
    let cancelled = false;
    setIsLoading(true);
    setError(null);
    const ctx = new AudioContext();
    ctxRef.current = ctx;

    const decodeMain = file.arrayBuffer().then(ab => ctx.decodeAudioData(ab));

    const irLoads = PRESETS.filter(p => p.file).map(p =>
      fetch(p.file!).then(r => r.arrayBuffer()).then(ab => ctx.decodeAudioData(ab))
        .then(buf => ({ id: p.id, buf })).catch(() => null)
    );

    Promise.all([decodeMain, Promise.all(irLoads)]).then(([decoded, irs]) => {
      if (cancelled) return;
      bufferRef.current = decoded;
      setDuration(decoded.duration);
      const irMap: Record<string, AudioBuffer> = {};
      irs.forEach(r => { if (r) irMap[r.id] = r.buf; });
      setIrBuffers(irMap);
      const bpm = detectBPM(decoded);
      setDetectedBPM(bpm);
      setTargetBPM(Math.round(bpm * 0.75));
      setIsLoading(false);
      setTimeout(() => drawWaveform(decoded, null, 1, 0), 50);
    }).catch(err => {
      if (cancelled) return;
      setError("Could not decode audio.");
      setIsLoading(false);
    });

    return () => { cancelled = true; cancelAnimationFrame(rafRef.current); ctx.close(); };
  }, [file]);

  const getImpulse = useCallback((ctx: AudioContext | OfflineAudioContext, preset: string, decay: number): AudioBuffer => {
    if (irBuffers[preset]) return irBuffers[preset];
    const sr = ctx.sampleRate;
    const len = Math.floor(sr * decay);
    const buf = ctx.createBuffer(2, len, sr);
    for (let c = 0; c < 2; c++) {
      const ch = buf.getChannelData(c);
      for (let i = 0; i < len; i++) ch[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 2);
    }
    return buf;
  }, [irBuffers]);

  const drawWaveform = useCallback((
    buffer: AudioBuffer,
    loop: LoopRegion | null,
    z: number,
    zOff: number,
    playhead?: number
  ) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const W = canvas.width, H = canvas.height;
    const data = buffer.getChannelData(0);
    const dur = buffer.duration;

    // Visible range
    const visStart = zOff;
    const visEnd = Math.min(zOff + dur / z, dur);
    const visDur = visEnd - visStart;

    const startSample = Math.floor((visStart / dur) * data.length);
    const endSample = Math.floor((visEnd / dur) * data.length);
    const step = Math.ceil((endSample - startSample) / W);
    const amp = H / 2;

    ctx.clearRect(0, 0, W, H);

    // Loop region background
    if (loop) {
      const lx = ((loop.start - visStart) / visDur) * W;
      const lw = ((loop.end - loop.start) / visDur) * W;
      ctx.fillStyle = "rgba(167,139,250,0.15)";
      ctx.fillRect(lx, 0, lw, H);
    }

    // Waveform
    for (let i = 0; i < W; i++) {
      let min = 1, max = -1;
      for (let j = 0; j < step; j++) {
        const v = data[startSample + i * step + j] || 0;
        if (v < min) min = v;
        if (v > max) max = v;
      }
      ctx.fillStyle = "#6d28d9";
      ctx.fillRect(i, (1 + min) * amp, 1, Math.max(1, (max - min) * amp));
    }

    // Loop region borders
    if (loop) {
      const lx = ((loop.start - visStart) / visDur) * W;
      const rx = ((loop.end - visStart) / visDur) * W;
      ctx.fillStyle = "#a78bfa";
      ctx.fillRect(lx - 1, 0, 2, H);
      ctx.fillRect(rx - 1, 0, 2, H);
    }

    // Playhead
    if (playhead !== undefined) {
      const px = ((playhead - visStart) / visDur) * W;
      ctx.fillStyle = "#f0abfc";
      ctx.fillRect(px - 1, 0, 2, H);
    }
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
    fx: Effects
  ): AudioBufferSourceNode => {
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.playbackRate.value = fx.speed;
    if (fx.preservePitch) source.detune.value = -Math.log2(fx.speed) * 1200;

    const convolver = ctx.createConvolver();
    convolver.buffer = getImpulse(ctx, fx.reverbPreset, fx.reverbDecay);

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
  }, [getImpulse]);

  const startPlayback = useCallback((offset = 0) => {
    const ctx = ctxRef.current;
    const buffer = bufferRef.current;
    if (!ctx || !buffer) return;
    if (ctx.state === "suspended") ctx.resume();
    stopPlayback();

    const fx = effectsRef.current;
    const loop = loopRef.current;
    const startAt = loop ? loop.start : offset;
    const endAt = loop ? loop.end : buffer.duration;

    const source = buildGraph(ctx, buffer, ctx.destination, fx);
    source.loop = !!loop;
    if (loop) {
      source.loopStart = loop.start;
      source.loopEnd = loop.end;
    }
    sourceRef.current = source;
    startTimeRef.current = ctx.currentTime;
    startOffsetRef.current = startAt;

    source.start(0, startAt, loop ? undefined : (endAt - startAt) / fx.speed);
    source.onended = () => {
      if (!loopRef.current) {
        setIsPlaying(false);
        setCurrentTime(0);
        startOffsetRef.current = 0;
      }
    };
    setIsPlaying(true);

    const tick = () => {
      const ctx2 = ctxRef.current;
      const buf = bufferRef.current;
      if (!ctx2 || !buf) return;
      const elapsed = (ctx2.currentTime - startTimeRef.current) * effectsRef.current.speed;
      let t = startOffsetRef.current + elapsed;
      const lr = loopRef.current;
      if (lr) {
        const loopLen = lr.end - lr.start;
        if (t > lr.end) t = lr.start + ((t - lr.start) % loopLen);
      }
      t = Math.min(t, buf.duration);
      setCurrentTime(t);
      drawWaveform(buf, loopRef.current, zoom, zoomOffset, t);
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  }, [buildGraph, stopPlayback, drawWaveform, zoom, zoomOffset]);

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

  const updateEffect = (key: keyof Effects, val: number | boolean | string) => {
    setEffects(prev => {
      const next = { ...prev, [key]: val };
      if (isPlaying) {
        const ctx = ctxRef.current;
        if (ctx) {
          const elapsed = (ctx.currentTime - startTimeRef.current) * prev.speed;
          startOffsetRef.current = Math.min(startOffsetRef.current + elapsed, duration);
        }
        setTimeout(() => startPlayback(startOffsetRef.current), 10);
      }
      return next;
    });
  };

  // BPM snap
  const applyTargetBPM = () => {
    if (!detectedBPM || !targetBPM) return;
    const speed = Math.min(1.0, Math.max(0.25, targetBPM / detectedBPM));
    updateEffect("speed", speed);
  };

  // Canvas interaction — seek + loop drag
  const canvasTimeAt = useCallback((clientX: number): number => {
    const canvas = canvasRef.current;
    if (!canvas || !bufferRef.current) return 0;
    const rect = canvas.getBoundingClientRect();
    const frac = (clientX - rect.left) / rect.width;
    const dur = bufferRef.current.duration;
    const visStart = zoomOffset;
    const visDur = dur / zoom;
    return Math.max(0, Math.min(dur, visStart + frac * visDur));
  }, [zoom, zoomOffset]);

  const handleCanvasMouseDown = (e: React.MouseEvent) => {
    if (e.shiftKey) {
      const t = canvasTimeAt(e.clientX);
      setLoopDragStart(t);
      setIsDraggingLoop(true);
      setLoopRegion({ start: t, end: t });
    } else {
      const t = canvasTimeAt(e.clientX);
      startOffsetRef.current = t;
      setCurrentTime(t);
      if (isPlaying) startPlayback(t);
      else if (bufferRef.current) drawWaveform(bufferRef.current, loopRegion, zoom, zoomOffset, t);
    }
  };

  const handleCanvasMouseMove = (e: React.MouseEvent) => {
    if (!isDraggingLoop || loopDragStart === null) return;
    const t = canvasTimeAt(e.clientX);
    const start = Math.min(loopDragStart, t);
    const end = Math.max(loopDragStart, t);
    setLoopRegion({ start, end });
    if (bufferRef.current) drawWaveform(bufferRef.current, { start, end }, zoom, zoomOffset, currentTime);
  };

  const handleCanvasMouseUp = () => {
    if (isDraggingLoop && loopRegion && loopRegion.end - loopRegion.start < 0.1) {
      setLoopRegion(null);
    }
    setIsDraggingLoop(false);
    setLoopDragStart(null);
  };

  // Zoom with scroll wheel
  const handleWheel = (e: React.WheelEvent) => {
    e.preventDefault();
    const buf = bufferRef.current;
    if (!buf) return;
    const dur = buf.duration;
    const delta = e.deltaY > 0 ? -0.5 : 0.5;
    const newZoom = Math.max(1, Math.min(20, zoom + delta));
    // Keep center point stable
    const canvas = canvasRef.current;
    if (canvas) {
      const rect = canvas.getBoundingClientRect();
      const frac = (e.clientX - rect.left) / rect.width;
      const focusTime = zoomOffset + frac * (dur / zoom);
      const newVisDur = dur / newZoom;
      const newOffset = Math.max(0, Math.min(dur - newVisDur, focusTime - frac * newVisDur));
      setZoom(newZoom);
      setZoomOffset(newOffset);
      drawWaveform(buf, loopRegion, newZoom, newOffset, currentTime);
    }
  };

  useEffect(() => {
    if (!isLoading && bufferRef.current) {
      drawWaveform(bufferRef.current, loopRegion, zoom, zoomOffset, currentTime);
    }
  }, [isLoading, zoom, zoomOffset, loopRegion]);

  const encodeWav = (buffer: AudioBuffer): Blob => {
    const nc = buffer.numberOfChannels, sr = buffer.sampleRate, ns = buffer.length;
    const ba = nc * 2, ds = ns * ba;
    const ab = new ArrayBuffer(44 + ds);
    const v = new DataView(ab);
    const ws = (o: number, s: string) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    ws(0, "RIFF"); v.setUint32(4, 36 + ds, true); ws(8, "WAVE"); ws(12, "fmt ");
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, nc, true);
    v.setUint32(24, sr, true); v.setUint32(28, sr * ba, true); v.setUint16(32, ba, true);
    v.setUint16(34, 16, true); ws(36, "data"); v.setUint32(40, ds, true);
    let off = 44;
    for (let i = 0; i < ns; i++) for (let c = 0; c < nc; c++) {
      const s = Math.max(-1, Math.min(1, buffer.getChannelData(c)[i]));
      v.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7fff, true); off += 2;
    }
    return new Blob([ab], { type: "audio/wav" });
  };

  const handleExport = async () => {
    setExporting(true); setExportProgress(5); setExportStatus("Uploading file...");
    try {
      const job = await submitJob(file, effects.speed, effects.reverbWet, effects.reverbDecay, exportFormat);
      setExportProgress(20); setExportStatus("Processing with FFmpeg...");
      let current = job;
      let attempts = 0;
      while (current.status === "pending" || current.status === "processing") {
        await new Promise(r => setTimeout(r, 1000));
        current = await pollJob(job.id);
        attempts++;
        setExportProgress(Math.min(20 + attempts * 5, 85));
        if (attempts > 120) throw new Error("Job timed out");
      }
      if (current.status === "failed") throw new Error(current.error ?? "Job failed");
      setExportProgress(90); setExportStatus("Downloading...");
      const a = document.createElement("a");
      a.href = downloadUrl(job.id);
      a.download = file.name.replace(/\.[^.]+$/, "") + "_slowed_reverb." + exportFormat;
      a.click();
      setExportProgress(100); setExportStatus("Done!");
      setTimeout(() => { setExporting(false); setExportProgress(0); setExportStatus(""); }, 1500);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Export failed";
      setExportStatus("Error: " + msg);
      setTimeout(() => { setExporting(false); setExportProgress(0); setExportStatus(""); }, 3000);
    }
  };

  if (isLoading) return <div className="bg-zinc-900 rounded-2xl p-8 text-center text-zinc-400 text-sm">Decoding audio...</div>;
  if (error) return <div role="alert" className="bg-red-950/40 border border-red-800 rounded-2xl p-6 text-red-300 text-sm text-center">{error}</div>;

  return (
    <div className="bg-zinc-900 rounded-2xl p-6 space-y-5">

      {/* Waveform */}
      <div className="space-y-1">
        <div className="flex items-center justify-between">
          <p className="text-zinc-500 text-xs">
            {zoom > 1 ? `${zoom.toFixed(1)}x zoom · scroll to zoom · shift+drag to loop` : "scroll to zoom · shift+drag to loop"}
          </p>
          {loopRegion && (
            <button onClick={() => setLoopRegion(null)} className="text-zinc-500 hover:text-zinc-300 text-xs">
              clear loop
            </button>
          )}
        </div>
        <canvas
          ref={canvasRef}
          width={800} height={80}
          className="w-full h-20 block rounded-lg cursor-crosshair"
          onMouseDown={handleCanvasMouseDown}
          onMouseMove={handleCanvasMouseMove}
          onMouseUp={handleCanvasMouseUp}
          onMouseLeave={handleCanvasMouseUp}
          onWheel={handleWheel}
          aria-label="Waveform — scroll to zoom, shift+drag to set loop region"
        />
      </div>

      {/* Transport */}
      <div className="flex items-center gap-4">
        <button onClick={togglePlay} aria-label={isPlaying ? "Pause" : "Play"}
          className="w-12 h-12 rounded-full bg-violet-600 hover:bg-violet-500 flex items-center justify-center text-white text-lg transition-colors flex-shrink-0">
          {isPlaying ? "⏸" : "▶"}
        </button>
        <div className="flex-1 flex items-center gap-3">
          <span className="text-zinc-500 text-xs tabular-nums w-8">{fmt(currentTime)}</span>
          <input type="range" min={0} max={duration} step={0.1} value={currentTime}
            onChange={e => {
              const t = parseFloat(e.target.value);
              startOffsetRef.current = t; setCurrentTime(t);
              if (isPlaying) startPlayback(t);
              else if (bufferRef.current) drawWaveform(bufferRef.current, loopRegion, zoom, zoomOffset, t);
            }}
            aria-label="Seek" className="flex-1 accent-violet-500" />
          <span className="text-zinc-500 text-xs tabular-nums w-8 text-right">{fmt(duration)}</span>
        </div>
      </div>

      {/* BPM */}
      {detectedBPM && (
        <div className="flex items-center gap-3 py-2 px-3 bg-zinc-800 rounded-xl border border-zinc-700">
          <div className="text-zinc-400 text-xs flex-1">
            Detected <span className="text-zinc-200 font-medium">{detectedBPM} BPM</span>
          </div>
          <div className="flex items-center gap-2">
            <span className="text-zinc-500 text-xs">target</span>
            <input type="number" min={40} max={200} value={targetBPM ?? ""}
              onChange={e => setTargetBPM(parseInt(e.target.value))}
              className="w-16 bg-zinc-700 text-zinc-200 text-xs rounded px-2 py-1 border border-zinc-600 focus:outline-none focus:border-violet-500 tabular-nums"
              aria-label="Target BPM" />
            <span className="text-zinc-500 text-xs">BPM</span>
            <button onClick={applyTargetBPM}
              className="text-xs px-3 py-1 bg-violet-700 hover:bg-violet-600 text-white rounded-lg transition-colors">
              Apply
            </button>
          </div>
        </div>
      )}

      {/* Effects */}
      <div className="space-y-4 pt-2 border-t border-zinc-800">
        <p className="text-zinc-500 text-xs uppercase tracking-wider">Effects</p>

        <Slider label="Speed" value={effects.speed} min={0.25} max={1.0} step={0.01}
          display={`${Math.round(effects.speed * 100)}%`} onChange={v => updateEffect("speed", v)} />

        {/* Reverb preset */}
        <div className="flex items-center gap-3">
          <label className="text-zinc-300 text-sm w-28 flex-shrink-0">Reverb preset</label>
          <div className="flex-1 flex gap-2 flex-wrap">
            {PRESETS.map(p => (
              <button key={p.id} onClick={() => updateEffect("reverbPreset", p.id)}
                className={`text-xs px-3 py-1.5 rounded-lg transition-colors border ${
                  effects.reverbPreset === p.id
                    ? "bg-violet-600 border-violet-500 text-white"
                    : "bg-zinc-800 border-zinc-700 text-zinc-300 hover:border-zinc-500"
                }`}>
                {p.label}
              </button>
            ))}
          </div>
        </div>

        <Slider label="Reverb mix" value={effects.reverbWet} min={0} max={1} step={0.01}
          display={`${Math.round(effects.reverbWet * 100)}%`} onChange={v => updateEffect("reverbWet", v)} />
        <Slider label="Reverb decay" value={effects.reverbDecay} min={0.1} max={5} step={0.1}
          display={`${effects.reverbDecay.toFixed(1)}s`} onChange={v => updateEffect("reverbDecay", v)} />

        <div className="flex items-center gap-3">
          <span className="text-zinc-300 text-sm w-28 flex-shrink-0">Preserve pitch</span>
          <button role="switch" aria-checked={effects.preservePitch}
            onClick={() => updateEffect("preservePitch", !effects.preservePitch)}
            className={`relative w-10 h-6 rounded-full transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 ${effects.preservePitch ? "bg-violet-600" : "bg-zinc-700"}`}
            aria-label="Preserve pitch">
            <span className={`absolute top-1 w-4 h-4 rounded-full bg-white transition-transform ${effects.preservePitch ? "translate-x-5" : "translate-x-1"}`} />
          </button>
          <span className="text-zinc-500 text-xs">{effects.preservePitch ? "on — pitch stays constant" : "off — pitch drops with speed"}</span>
        </div>

        {loopRegion && (
          <div className="flex items-center gap-2 text-xs text-violet-300 bg-violet-950/30 rounded-lg px-3 py-2 border border-violet-800">
            <span>⟳</span>
            <span>Looping {fmt(loopRegion.start)} – {fmt(loopRegion.end)}</span>
          </div>
        )}
      </div>

      {/* Export */}
      <div className="pt-2 border-t border-zinc-800 space-y-3">
        <div className="flex items-center gap-3">
          <p className="text-zinc-500 text-xs uppercase tracking-wider flex-1">Export</p>
          <select value={exportFormat} onChange={e => setExportFormat(e.target.value as "wav" | "mp3")}
            disabled={exporting} aria-label="Export format"
            className="bg-zinc-800 text-zinc-300 text-xs rounded-lg px-2 py-1 border border-zinc-700 focus:outline-none focus:border-violet-500">
            <option value="mp3">MP3</option>
            <option value="wav">WAV</option>
          </select>
        </div>
        {exporting ? (
          <div className="space-y-2">
            <div className="w-full bg-zinc-800 rounded-full h-2 overflow-hidden">
              <div className="bg-violet-500 h-2 rounded-full transition-all duration-300" style={{ width: `${exportProgress}%` }}
                role="progressbar" aria-valuenow={exportProgress} aria-valuemin={0} aria-valuemax={100} />
            </div>
            <p className="text-zinc-500 text-xs text-center">{exportStatus}</p>
          </div>
        ) : (
          <button onClick={handleExport}
            className="w-full py-3 rounded-xl bg-violet-600 hover:bg-violet-500 text-white text-sm font-medium transition-colors">
            Export {exportFormat.toUpperCase()}
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
        onChange={e => onChange(parseFloat(e.target.value))}
        aria-label={label} aria-valuetext={display} className="flex-1 accent-violet-500" />
      <span className="text-zinc-400 text-sm tabular-nums w-12 text-right" aria-hidden="true">{display}</span>
    </div>
  );
}
'''.lstrip()

with open('components/AudioPlayer.tsx', 'w') as f:
    f.write(content)

print("✅ AudioPlayer.tsx written with all Tier 1 + Tier 2 features")
PYEOF

echo "✅ Done"
