SHELL := /bin/bash

.PHONY: build test vet fmt guard sqlc goose-up goose-status guard-strict

build:
	go build ./...

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -l -w .

guard:
	node /home/aseprohman/.agents/skills/backend-go-scaffold-implementator/scripts/periksa-batas-lapisan-go.mjs --root internal/modules

guard-strict:
	node /home/aseprohman/.agents/skills/backend-go-scaffold-implementator/scripts/periksa-batas-lapisan-go.mjs --root internal/modules --strict

sqlc:
	sqlc generate

# goose memakai DATABASE_URL dari environment (lihat .env.example)
goose-up:
	goose -dir db/migrations up

goose-status:
	goose -dir db/migrations status
