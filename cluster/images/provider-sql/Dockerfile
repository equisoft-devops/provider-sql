ARG GO_VERSION

# Build stage
FROM golang:${GO_VERSION} AS builder

RUN apk add --no-cache git

WORKDIR /workspace

COPY go.mod go.sum ./

RUN go mod download

COPY . .

# Build arguments for cross-compilation
ARG TARGETOS
ARG TARGETARCH

# Build the binary
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -a -installsuffix cgo -o provider \
    -ldflags="-s -w" \
    ./cmd/provider

# Runtime stage
FROM gcr.io/distroless/static@sha256:1f580b0a1922c3e54ae15b0758b5747b260bd99d39d40c2edb3e7f6e2452298b

# Copy the binary from builder stage
COPY --from=builder /workspace/provider /usr/local/bin/crossplane-sql-provider

USER 65532
ENTRYPOINT ["crossplane-sql-provider"]
