# alpine / trixie
ARG IMAGEBASE=trixie
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
FROM docker.io/library/rust:1.98.1-${IMAGEBASE} AS builder

RUN if command -v apk >/dev/null 2>&1; then \
            apk add --no-cache musl-dev; \
        fi
WORKDIR /src

COPY Cargo.toml Cargo.lock build.rs ./
COPY src ./src
RUN cargo build --locked --release

FROM docker.io/library/debian:trixie-slim AS runtime-trixie
FROM docker.io/library/alpine:3.24.2 AS runtime-alpine
FROM runtime-${IMAGEBASE}
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST

COPY --from=builder /src/target/release/rust-server /rust-server

LABEL io.wtt.upstream-runtime.image="${UPSTREAM_RUNTIME_IMAGE}" \
      io.wtt.upstream-runtime.digest="${UPSTREAM_RUNTIME_DIGEST}"
ENV WTT_UPSTREAM_RUNTIME_IMAGE="${UPSTREAM_RUNTIME_IMAGE}" \
    WTT_UPSTREAM_RUNTIME_DIGEST="${UPSTREAM_RUNTIME_DIGEST}"
USER 65532:65532
EXPOSE 8080 8443

ENTRYPOINT ["/rust-server"]
