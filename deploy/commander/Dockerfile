# Build context: repo root. Targets commander (default) and proxy are separate
# images; no signing private key enters the commander image/container.
FROM golang:1.27.1-alpine AS commander-build
WORKDIR /src
COPY commander/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/commander ./cmd/commander

FROM golang:1.27.1-alpine AS proxy-build
ARG VEHICLE_COMMAND_VERSION=v0.4.1
# Go's module checksum database verifies the pinned release. Build in a module
# context to honor upstream's replace directive (go install pkg@version cannot).
RUN go mod download github.com/teslamotors/vehicle-command@${VEHICLE_COMMAND_VERSION} \
    && cp -R /go/pkg/mod/github.com/teslamotors/vehicle-command@${VEHICLE_COMMAND_VERSION} /src \
    && cd /src && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/tesla-http-proxy ./cmd/tesla-http-proxy

FROM alpine:3.23 AS runtime
RUN apk add --no-cache ca-certificates && addgroup -g 65532 volta && adduser -D -u 65532 -G volta volta
USER 65532:65532

FROM runtime AS proxy
COPY --from=proxy-build /out/tesla-http-proxy /usr/local/bin/tesla-http-proxy
ENTRYPOINT ["/usr/local/bin/tesla-http-proxy"]

FROM runtime AS commander
COPY --from=commander-build /out/commander /usr/local/bin/commander
ENTRYPOINT ["/usr/local/bin/commander"]
