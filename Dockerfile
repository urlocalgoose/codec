# Codec sync server + web app in one container.
#
#   docker build -t codec .
#   docker run -p 8787:8787 -v codec-data:/data -e LOUD_AUTH_TOKEN=change-me codec
#
# The web app, API, and media all serve from :8787; library data and
# media blobs persist in the /data volume.

FROM oven/bun:1 AS web
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY svelte.config.js vite.config.js tsconfig.json ./
COPY src ./src
COPY static ./static
RUN bun run build

FROM golang:1.26-alpine AS server
WORKDIR /app
COPY sync-server/go.mod sync-server/go.sum ./
RUN go mod download
COPY sync-server ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /codec-sync-server ./cmd/codec-sync-server

FROM alpine:3.20
RUN adduser -D -u 1000 codec
COPY --from=server /codec-sync-server /usr/local/bin/codec-sync-server
COPY --from=web /app/build /srv/codec-web
USER codec
VOLUME /data
EXPOSE 8787
ENTRYPOINT ["codec-sync-server", "--addr", ":8787", "--data", "/data", "--web", "/srv/codec-web"]
