#!/bin/bash
# Run from ~/slowreverb/apps/web
# Fixes waveform not drawing on initial load

# Use python to do a targeted replacement in AudioPlayer.tsx
python3 << 'PYEOF'
with open('components/AudioPlayer.tsx', 'r') as f:
    content = f.read()

# Fix 1: drawWaveform needs to use the canvas ref which may not be ready at decode time
# We add a useEffect that redraws when isLoading transitions to false
old = "  // Draw waveform on canvas\n  const drawWaveform = (buffer: AudioBuffer) => {"
new = "  // Redraw waveform after loading completes (canvas may not be in DOM during decode)\n  useEffect(() => {\n    if (!isLoading && bufferRef.current) {\n      // Small timeout lets the canvas mount before we try to draw\n      setTimeout(() => drawWaveform(bufferRef.current!), 50);\n    }\n  // eslint-disable-next-line react-hooks/exhaustive-deps\n  }, [isLoading]);\n\n  // Draw waveform on canvas\n  const drawWaveform = (buffer: AudioBuffer) => {"

content = content.replace(old, new)

with open('components/AudioPlayer.tsx', 'w') as f:
    f.write(content)

print("✅ Waveform fix applied")
PYEOF
