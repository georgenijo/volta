# Two images from one build stage:
#
#   --target consumer  volta-telemetry-consumer: Kafka -> Postgres normalizer
#                      and private usage meter. Static binary on distroless
#                      nonroot (uid 65532).
#   --target receiver  the official, unmodified Tesla Fleet Telemetry v0.9.5
#                      image (pinned by digest) with volta-receiver-guard as
#                      PID 1. The guard runs /fleet-telemetry as its child,
#                      owns the container's stdout/stderr and emits only fixed
#                      event codes (the receiver logs VINs and addresses on
#                      error paths), and serves receiver liveness on the
#                      internal network.
FROM golang:1.27.1-bookworm@sha256:8d48e12ec56735e9358640898b9d9b9fcca110612ed8a5567438c0a1baa24e66 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/volta-telemetry-consumer ./cmd/volta-telemetry-consumer && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/volta-receiver-guard ./cmd/volta-receiver-guard

FROM tesla/fleet-telemetry:v0.9.5@sha256:7cb5f429210128b8edc5aac1e403589315893106f4c5a3ff85cb32213e2f8e37 AS receiver
COPY --from=build /out/volta-receiver-guard /volta-receiver-guard
USER 65532:65532
ENTRYPOINT ["/volta-receiver-guard", "--", "/fleet-telemetry"]
CMD ["-config", "/etc/fleet-telemetry/config.json"]
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/volta-receiver-guard", "healthcheck"]

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS consumer
COPY --from=build /out/volta-telemetry-consumer /volta-telemetry-consumer
USER 65532:65532
ENTRYPOINT ["/volta-telemetry-consumer"]
