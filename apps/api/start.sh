#!/bin/bash
export PORT=8081
export ALLOWED_ORIGIN=http://localhost:3001
export DATABASE_URL="postgres://slowreverb:slowreverb_dev@localhost/slowreverb?sslmode=disable"

cd "$(dirname "$0")"
exec ./api
