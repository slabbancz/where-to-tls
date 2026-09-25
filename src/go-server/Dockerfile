# Multi-stage Dockerfile for Go server (Contract §4: distroless static)
# alpine / trixie
ARG IMAGEBASE=trixie
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
FROM docker.io/library/golang:1.27.1-${IMAGEBASE} AS builder

WORKDIR /src
COPY go.mod ./
COPY *.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /go-server .

FROM gcr.io/distroless/static:latest
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST

COPY --from=builder /go-server /go-server

LABEL io.wtt.upstream-runtime.image="${UPSTREAM_RUNTIME_IMAGE}" \
      io.wtt.upstream-runtime.digest="${UPSTREAM_RUNTIME_DIGEST}"
ENV WTT_UPSTREAM_RUNTIME_IMAGE="${UPSTREAM_RUNTIME_IMAGE}" \
    WTT_UPSTREAM_RUNTIME_DIGEST="${UPSTREAM_RUNTIME_DIGEST}"
USER 65532:65532
EXPOSE 8080 8443

ENTRYPOINT ["/go-server"]
