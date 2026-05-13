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
