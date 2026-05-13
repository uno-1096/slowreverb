# SlowReverb

A full-stack audio processing app. Upload an MP3, preview it slowed + reverbed in real time, export as MP3 or WAV, and separate stems with AI.

**Live at [slowreverb.unocloud.us](https://slowreverb.unocloud.us)**

## Features

- Real-time slow + reverb preview via Web Audio API
- Waveform visualizer with zoom and loop regions
- BPM detection + snap-to-grid slowing
- 5 reverb presets (Large Hall, Small Room, Plate, Cathedral, Synthetic)
- Pitch preservation toggle
- Server-side export via FFmpeg (MP3 + WAV)
- AI stem separation via Demucs (vocals, drums, bass, instruments)
- Per-stem independent speed, reverb, volume controls
- S3 output storage with signed URLs + 24h auto-delete
- PostgreSQL job persistence

## Stack

- **Frontend**: Next.js 16 + TypeScript + Tailwind + Web Audio API
- **Backend API**: Go + chi + PostgreSQL + Redis
- **Worker**: FFmpeg
- **Stem separation**: Python + Demucs (runs locally on GPU)
- **Storage**: AWS S3
- **Infra**: EC2 + Nginx + Let's Encrypt + systemd

## Structure
## Local Dev

```bash
# Frontend
cd apps/web && npm install && npm run dev

# API
cd apps/api && go run ./cmd/api

# Stems (requires GPU + demucs installed)
cd apps/stems && python3 app.py
```
