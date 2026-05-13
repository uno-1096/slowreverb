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
