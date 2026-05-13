package jobs

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
)

type Handler struct {
	store   Store
	workDir string
}

func NewHandler(store Store) *Handler {
	workDir := os.Getenv("WORK_DIR")
	if workDir == "" {
		workDir = "/tmp/slowreverb"
	}
	os.MkdirAll(workDir, 0755)
	return &Handler{store: store, workDir: workDir}
}

func (h *Handler) CreateJob(w http.ResponseWriter, r *http.Request) {
	// Max 200MB upload
	r.Body = http.MaxBytesReader(w, r.Body, 200<<20)
	if err := r.ParseMultipartForm(200 << 20); err != nil {
		http.Error(w, `{"error":"file too large"}`, http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, `{"error":"missing file"}`, http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Parse effect params
	speed := parseFloat(r.FormValue("speed"), 0.75)
	reverbWet := parseFloat(r.FormValue("reverb_wet"), 0.5)
	reverbDecay := parseFloat(r.FormValue("reverb_decay"), 2.0)

	format := r.FormValue("format")
	if format != "mp3" && format != "wav" {
		format = "wav"
	}

	// Clamp values to safe ranges
	speed = clamp(speed, 0.25, 1.0)
	reverbWet = clamp(reverbWet, 0.0, 1.0)
	reverbDecay = clamp(reverbDecay, 0.1, 10.0)

	id := uuid.New().String()
	inputPath := filepath.Join(h.workDir, id+"_input"+filepath.Ext(header.Filename))
	ext := ".wav"
	if format == "mp3" {
		ext = ".mp3"
	}
	outputPath := filepath.Join(h.workDir, id+"_output"+ext)

	// Save uploaded file
	dst, err := os.Create(inputPath)
	if err != nil {
		http.Error(w, `{"error":"could not save file"}`, http.StatusInternalServerError)
		return
	}
	if _, err := io.Copy(dst, file); err != nil {
		dst.Close()
		http.Error(w, `{"error":"could not save file"}`, http.StatusInternalServerError)
		return
	}
	dst.Close()

	job := &Job{
		ID:          id,
		FileName:    header.Filename,
		Status:      StatusPending,
		Speed:       speed,
		ReverbWet:   reverbWet,
		ReverbDecay: reverbDecay,
		Format:      format,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
	}
	h.store.Create(job)

	// Process in background
	go h.processJob(job, inputPath, outputPath)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(job)
}

func (h *Handler) GetJob(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	job, ok := h.store.Get(id)
	if !ok {
		http.Error(w, `{"error":"job not found"}`, http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(job)
}

func (h *Handler) DownloadJob(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	job, ok := h.store.Get(id)
	if !ok {
		http.Error(w, `{"error":"job not found"}`, http.StatusNotFound)
		return
	}
	if job.Status != StatusDone {
		http.Error(w, fmt.Sprintf(`{"error":"job not ready","status":"%s"}`, job.Status), http.StatusConflict)
		return
	}
	if _, err := os.Stat(job.OutputPath); err != nil {
		http.Error(w, `{"error":"output file missing"}`, http.StatusInternalServerError)
		return
	}

	baseName := job.FileName
	if ext := filepath.Ext(baseName); ext != "" {
		baseName = baseName[:len(baseName)-len(ext)]
	}
	contentType := "audio/wav"
	dlExt := ".wav"
	if job.Format == "mp3" {
		contentType = "audio/mpeg"
		dlExt = ".mp3"
	}
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_slowed_reverb%s"`, baseName, dlExt))
	w.Header().Set("Content-Type", contentType)
	http.ServeFile(w, r, job.OutputPath)
}

func (h *Handler) processJob(job *Job, inputPath, outputPath string) {
	job.Status = StatusProcessing
	h.store.Update(job)

	// Build FFmpeg filter chain
	// atempo only works 0.5-2.0 so chain if needed
	atempoFilters := buildAtempo(job.Speed)

	// aecho: in_gain out_gain delay decay (simple reverb)
	echoDelay := 60.0
	echoDecay := job.ReverbDecay * 0.3
	if echoDecay > 0.9 {
		echoDecay = 0.9
	}
	dryGain := 1.0 - job.ReverbWet
	wetGain := job.ReverbWet

	filter := fmt.Sprintf(
		"%s,asplit=2[dry][wet];[wet]aecho=%.2f:%.2f:%.0f:%.2f[reverb];[dry][reverb]amix=inputs=2:weights=%.2f %.2f",
		atempoFilters,
		1.0, 1.0,
		echoDelay,
		echoDecay,
		dryGain,
		wetGain,
	)

	args := []string{"-y", "-i", inputPath, "-af", filter, "-ar", "44100", "-ac", "2"}
	if job.Format == "mp3" {
		args = append(args, "-codec:a", "libmp3lame", "-qscale:a", "2")
	}
	args = append(args, outputPath)

	cmd := exec.Command("ffmpeg", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		job.Status = StatusFailed
		job.Error = fmt.Sprintf("ffmpeg error: %s", string(out))
		h.store.Update(job)
		os.Remove(inputPath)
		return
	}

	job.Status = StatusDone
	job.OutputPath = outputPath
	h.store.Update(job)
	os.Remove(inputPath) // clean up input
}

// buildAtempo chains atempo filters to handle speeds outside 0.5-2.0
func buildAtempo(speed float64) string {
	if speed >= 0.5 {
		return fmt.Sprintf("atempo=%.4f", speed)
	}
	// For speeds below 0.5, chain two atempo filters
	// e.g. 0.25 = atempo=0.5,atempo=0.5
	half := speed * 2
	return fmt.Sprintf("atempo=%.4f,atempo=0.5000", half)
}

func parseFloat(s string, def float64) float64 {
	if s == "" {
		return def
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return def
	}
	return v
}

func clamp(v, min, max float64) float64 {
	if v < min {
		return min
	}
	if v > max {
		return max
	}
	return v
}
