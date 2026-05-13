#!/bin/bash
# Run from ~/slowreverb/apps/api

# Update handler to support format param
python3 << 'PYEOF'
with open('internal/jobs/handler.go', 'r') as f:
    content = f.read()

# Add format field parsing after reverbDecay line
old = '''	// Clamp values to safe ranges
	speed = clamp(speed, 0.25, 1.0)'''

new = '''	format := r.FormValue("format")
	if format != "mp3" && format != "wav" {
		format = "wav"
	}

	// Clamp values to safe ranges
	speed = clamp(speed, 0.25, 1.0)'''

content = content.replace(old, new)

# Add format to job struct creation
old = '''	job := &Job{
		ID:          id,
		FileName:    header.Filename,
		Status:      StatusPending,
		Speed:       speed,
		ReverbWet:   reverbWet,
		ReverbDecay: reverbDecay,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
	}'''

new = '''	job := &Job{
		ID:          id,
		FileName:    header.Filename,
		Status:      StatusPending,
		Speed:       speed,
		ReverbWet:   reverbWet,
		ReverbDecay: reverbDecay,
		Format:      format,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
	}'''

content = content.replace(old, new)

# Update outputPath to use correct extension
old = '''	outputPath := filepath.Join(h.workDir, id+"_output.wav")'''
new = '''	ext := ".wav"
	if format == "mp3" {
		ext = ".mp3"
	}
	outputPath := filepath.Join(h.workDir, id+"_output"+ext)'''

content = content.replace(old, new)

# Update download content type
old = '''	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_slowed_reverb.wav"`, baseName))
	w.Header().Set("Content-Type", "audio/wav")'''

new = '''	contentType := "audio/wav"
	dlExt := ".wav"
	if job.Format == "mp3" {
		contentType = "audio/mpeg"
		dlExt = ".mp3"
	}
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_slowed_reverb%s"`, baseName, dlExt))
	w.Header().Set("Content-Type", contentType)'''

content = content.replace(old, new)

# Update processJob to use format
old = '''	args := []string{
		"-y",
		"-i", inputPath,
		"-af", filter,
		"-ar", "44100",
		"-ac", "2",
		outputPath,
	}'''

new = '''	args := []string{"-y", "-i", inputPath, "-af", filter, "-ar", "44100", "-ac", "2"}
	if job.Format == "mp3" {
		args = append(args, "-codec:a", "libmp3lame", "-qscale:a", "2")
	}
	args = append(args, outputPath)'''

content = content.replace(old, new)

with open('internal/jobs/handler.go', 'w') as f:
    f.write(content)

print("✅ handler.go updated with format support")
PYEOF

# Add Format field to Job struct
python3 << 'PYEOF'
with open('internal/jobs/store.go', 'r') as f:
    content = f.read()

old = '''	OutputPath  string    `json:"output_path,omitempty"`'''
new = '''	Format      string    `json:"format"`
	OutputPath  string    `json:"output_path,omitempty"`'''

content = content.replace(old, new)

with open('internal/jobs/store.go', 'w') as f:
    f.write(content)

print("✅ store.go updated with Format field")
PYEOF

echo "✅ MP3 export backend ready — now rebuild"
