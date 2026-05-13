#!/bin/bash
# Run from ~/slowreverb/apps/web

# Update api.ts to pass format
python3 << 'PYEOF'
with open('lib/api.ts', 'r') as f:
    content = f.read()

old = '''export async function submitJob(
  file: File,
  speed: number,
  reverbWet: number,
  reverbDecay: number
): Promise<Job> {
  const form = new FormData();
  form.append("file", file);
  form.append("speed", String(speed));
  form.append("reverb_wet", String(reverbWet));
  form.append("reverb_decay", String(reverbDecay));'''

new = '''export async function submitJob(
  file: File,
  speed: number,
  reverbWet: number,
  reverbDecay: number,
  format: "wav" | "mp3" = "wav"
): Promise<Job> {
  const form = new FormData();
  form.append("file", file);
  form.append("speed", String(speed));
  form.append("reverb_wet", String(reverbWet));
  form.append("reverb_decay", String(reverbDecay));
  form.append("format", format);'''

content = content.replace(old, new)

# Update Job interface to include format
old = '  error?: string;\n}'
new = '  format: string;\n  error?: string;\n}'
content = content.replace(old, new)

with open('lib/api.ts', 'w') as f:
    f.write(content)

print("✅ api.ts updated")
PYEOF

# Update AudioPlayer to add MP3 option and pass format
python3 << 'PYEOF'
with open('components/AudioPlayer.tsx', 'r') as f:
    content = f.read()

# Add exportFormat state
old = '  const [exporting, setExporting] = useState(false);\n  const [exportProgress, setExportProgress] = useState(0);\n  const [exportStatus, setExportStatus] = useState("");\n  const [irBuffer, setIrBuffer] = useState<AudioBuffer | null>(null);'
new = '  const [exporting, setExporting] = useState(false);\n  const [exportProgress, setExportProgress] = useState(0);\n  const [exportStatus, setExportStatus] = useState("");\n  const [exportFormat, setExportFormat] = useState<"wav" | "mp3">("mp3");\n  const [irBuffer, setIrBuffer] = useState<AudioBuffer | null>(null);'
content = content.replace(old, new)

# Pass format to submitJob
old = '      const job = await submitJob(file, effects.speed, effects.reverbWet, effects.reverbDecay);'
new = '      const job = await submitJob(file, effects.speed, effects.reverbWet, effects.reverbDecay, exportFormat);'
content = content.replace(old, new)

# Update download filename to use job format
old = "      const a = document.createElement(\"a\");\n      a.href = downloadUrl(job.id);\n      a.download = file.name.replace(/\\.[^.]+$/, \"\") + \"_slowed_reverb.wav\";"
new = "      const a = document.createElement(\"a\");\n      a.href = downloadUrl(job.id);\n      const dlExt = job.format === \"mp3\" ? \".mp3\" : \".wav\";\n      a.download = file.name.replace(/\\.[^.]+$/, \"\") + \"_slowed_reverb\" + dlExt;"
content = content.replace(old, new)

# Update export section UI to include format selector
old = '      <div className="pt-2 border-t border-zinc-800 space-y-3">\n        <p className="text-zinc-500 text-xs uppercase tracking-wider">Export</p>\n        {exporting ? ('
new = '''      <div className="pt-2 border-t border-zinc-800 space-y-3">
        <div className="flex items-center gap-3">
          <p className="text-zinc-500 text-xs uppercase tracking-wider flex-1">Export</p>
          <select
            value={exportFormat}
            onChange={(e) => setExportFormat(e.target.value as "wav" | "mp3")}
            disabled={exporting}
            aria-label="Export format"
            className="bg-zinc-800 text-zinc-300 text-xs rounded-lg px-2 py-1 border border-zinc-700 focus:outline-none focus:border-violet-500"
          >
            <option value="mp3">MP3</option>
            <option value="wav">WAV</option>
          </select>
        </div>
        {exporting ? ('''

content = content.replace(old, new)

# Fix closing bracket — add one more ) to match the new div structure
old = '''        ) : (
          <button onClick={handleExport}
            className="w-full py-3 rounded-xl bg-violet-600 hover:bg-violet-500 text-white text-sm font-medium transition-colors"
            aria-label="Export processed audio as WAV">
            Export WAV
          </button>
        )}
      </div>'''

new = '''        ) : (
          <button onClick={handleExport}
            className="w-full py-3 rounded-xl bg-violet-600 hover:bg-violet-500 text-white text-sm font-medium transition-colors"
            aria-label="Export processed audio">
            Export {exportFormat.toUpperCase()}
          </button>
        )}
      </div>'''

content = content.replace(old, new)

with open('components/AudioPlayer.tsx', 'w') as f:
    f.write(content)

print("✅ AudioPlayer.tsx updated with format selector")
PYEOF

echo "✅ Frontend MP3 support done"
