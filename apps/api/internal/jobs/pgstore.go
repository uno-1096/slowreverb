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
