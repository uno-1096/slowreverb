#!/bin/bash
# Run from ~/slowreverb/apps/api

# Create migrations folder and schema
mkdir -p migrations

cat > migrations/001_create_jobs.sql << 'EOF'
CREATE TABLE IF NOT EXISTS jobs (
  id          TEXT PRIMARY KEY,
  file_name   TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending',
  speed       DOUBLE PRECISION NOT NULL DEFAULT 0.75,
  reverb_wet  DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  reverb_decay DOUBLE PRECISION NOT NULL DEFAULT 2.0,
  format      TEXT NOT NULL DEFAULT 'wav',
  output_path TEXT,
  error       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
EOF

# Apply migration
PGPASSWORD=slowreverb_dev psql -U slowreverb -d slowreverb -h localhost -f migrations/001_create_jobs.sql
echo "✅ Migration applied"

# New postgres store
cat > internal/jobs/pgstore.go << 'EOF'
package jobs

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/lib/pq"
)

type PGStore struct {
	db *sql.DB
}

func NewPGStore(dsn string) (*PGStore, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping db: %w", err)
	}
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)
	return &PGStore{db: db}, nil
}

func (s *PGStore) Create(job *Job) {
	_, err := s.db.Exec(`
		INSERT INTO jobs (id, file_name, status, speed, reverb_wet, reverb_decay, format, created_at, updated_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		job.ID, job.FileName, job.Status,
		job.Speed, job.ReverbWet, job.ReverbDecay,
		job.Format, job.CreatedAt, job.UpdatedAt,
	)
	if err != nil {
		fmt.Printf("pgstore create error: %v\n", err)
	}
}

func (s *PGStore) Get(id string) (*Job, bool) {
	row := s.db.QueryRow(`
		SELECT id, file_name, status, speed, reverb_wet, reverb_decay,
		       format, COALESCE(output_path,''), COALESCE(error,''), created_at, updated_at
		FROM jobs WHERE id=$1`, id)

	var j Job
	err := row.Scan(
		&j.ID, &j.FileName, &j.Status,
		&j.Speed, &j.ReverbWet, &j.ReverbDecay,
		&j.Format, &j.OutputPath, &j.Error,
		&j.CreatedAt, &j.UpdatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, false
	}
	if err != nil {
		fmt.Printf("pgstore get error: %v\n", err)
		return nil, false
	}
	return &j, true
}

func (s *PGStore) Update(job *Job) {
	job.UpdatedAt = time.Now()
	_, err := s.db.Exec(`
		UPDATE jobs SET status=$1, output_path=$2, error=$3, updated_at=$4
		WHERE id=$5`,
		job.Status, job.OutputPath, job.Error, job.UpdatedAt, job.ID,
	)
	if err != nil {
		fmt.Printf("pgstore update error: %v\n", err)
	}
}
EOF

# Update store.go to define a Store interface both backends satisfy
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
	Format      string    `json:"format"`
	OutputPath  string    `json:"output_path,omitempty"`
	Error       string    `json:"error,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// Store is implemented by both MemoryStore and PGStore
type Store interface {
	Create(job *Job)
	Get(id string) (*Job, bool)
	Update(job *Job)
}

// MemoryStore — used as fallback if no DB configured
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

# Update handler.go to use Store interface instead of *MemoryStore
python3 << 'PYEOF'
with open('internal/jobs/handler.go', 'r') as f:
    content = f.read()

content = content.replace(
    'type Handler struct {\n\tstore   *MemoryStore\n\tworkDir string\n}',
    'type Handler struct {\n\tstore   Store\n\tworkDir string\n}'
)
content = content.replace(
    'func NewHandler(store *MemoryStore) *Handler {',
    'func NewHandler(store Store) *Handler {'
)

with open('internal/jobs/handler.go', 'w') as f:
    f.write(content)

print("✅ handler.go updated to use Store interface")
PYEOF

# Update main.go to use PGStore when DATABASE_URL is set
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

	// Use PostgreSQL if DATABASE_URL is set, otherwise fall back to memory
	var store jobs.Store
	dsn := os.Getenv("DATABASE_URL")
	if dsn != "" {
		pg, err := jobs.NewPGStore(dsn)
		if err != nil {
			log.Fatalf("failed to connect to postgres: %v", err)
		}
		store = pg
		log.Println("Using PostgreSQL store")
	} else {
		store = jobs.NewMemoryStore()
		log.Println("Using in-memory store (set DATABASE_URL to persist jobs)")
	}

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

echo "✅ All PostgreSQL files written"
