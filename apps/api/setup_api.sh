#!/bin/bash
# Run from ~/slowreverb/apps/api

mkdir -p cmd/api internal/{jobs,middleware,storage}

# main.go
cat > cmd/api/main.go << 'EOF'
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"
	"github.com/uno-1096/slowreverb/api/internal/jobs"
	"github.com/uno-1096/slowreverb/api/internal/middleware"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	store := jobs.NewMemoryStore()
	handler := jobs.NewHandler(store)

	r := chi.NewRouter()
	r.Use(chimiddleware.Logger)
	r.Use(chimiddleware.Recoverer)
	r.Use(chimiddleware.RequestID)
	r.Use(middleware.CORS)

	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	r.Route("/api/v1", func(r chi.Router) {
		r.Post("/jobs", handler.CreateJob)
		r.Get("/jobs/{id}", handler.GetJob)
		r.Get("/jobs/{id}/download", handler.DownloadJob)
	})

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      r,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 120 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("API listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}
EOF

# internal/jobs/store.go — in-memory job store (no DB needed for local dev)
cat > internal/jobs/store.go << 'EOF'
package jobs

import (
	"sync"
	"time"
)

type Status string

const (
	StatusPending    Status = "pending"
	StatusProcessing Status = "processing"
	StatusDone       Status = "done"
	StatusFailed     Status = "failed"
)

type Job struct {
	ID          string    `json:"id"`
	FileName    string    `json:"file_name"`
	Status      Status    `json:"status"`
	Speed       float64   `json:"speed"`
	ReverbWet   float64   `json:"reverb_wet"`
	ReverbDecay float64   `json:"reverb_decay"`
	OutputPath  string    `json:"output_path,omitempty"`
	Error       string    `json:"error,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

type MemoryStore struct {
	mu   sync.RWMutex
	jobs map[string]*Job
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{jobs: make(map[string]*Job)}
}

func (s *MemoryStore) Create(job *Job) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.jobs[job.ID] = job
}

func (s *MemoryStore) Get(id string) (*Job, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	j, ok := s.jobs[id]
	return j, ok
}

func (s *MemoryStore) Update(job *Job) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job.UpdatedAt = time.Now()
	s.jobs[job.ID] = job
}
EOF

# internal/jobs/handler.go
cat > internal/jobs/handler.go << 'EOF'
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
	store   *MemoryStore
	workDir string
}

func NewHandler(store *MemoryStore) *Handler {
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

	// Clamp values to safe ranges
	speed = clamp(speed, 0.25, 1.0)
	reverbWet = clamp(reverbWet, 0.0, 1.0)
	reverbDecay = clamp(reverbDecay, 0.1, 10.0)

	id := uuid.New().String()
	inputPath := filepath.Join(h.workDir, id+"_input"+filepath.Ext(header.Filename))
	outputPath := filepath.Join(h.workDir, id+"_output.wav")

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
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_slowed_reverb.wav"`, baseName))
	w.Header().Set("Content-Type", "audio/wav")
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

	args := []string{
		"-y",
		"-i", inputPath,
		"-af", filter,
		"-ar", "44100",
		"-ac", "2",
		outputPath,
	}

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
EOF

# internal/middleware/cors.go
cat > internal/middleware/cors.go << 'EOF'
package middleware

import "net/http"

func CORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "http://localhost:3000")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
EOF

echo "✅ API files written"
