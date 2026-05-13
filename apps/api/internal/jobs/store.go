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
