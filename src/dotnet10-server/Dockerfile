# Multi-stage Dockerfile for .NET 10 server.
# alpine / resolute
ARG IMAGEBASE=resolute
ARG DOTNET_AOT=false
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
FROM mcr.microsoft.com/dotnet/sdk:10.0-${IMAGEBASE} AS build
WORKDIR /src
COPY dotnet10-server.csproj ./
RUN dotnet restore
COPY *.cs ./
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/sdk:10.0-${IMAGEBASE}-aot AS build-aot
ARG IMAGEBASE
WORKDIR /src
COPY dotnet10-server.csproj ./
COPY *.cs ./
RUN if [ "${IMAGEBASE}" = alpine ]; then rid=linux-musl-x64; else rid=linux-x64; fi \
    && dotnet restore -r "$rid" -p:PublishAot=true \
    && dotnet publish --no-restore -r "$rid" -c Release -o /app/publish \
    -p:PublishAot=true -p:TreatWarningsAsErrors=true -p:ILLinkTreatWarningsAsErrors=true

FROM mcr.microsoft.com/dotnet/aspnet:10.0-${IMAGEBASE} AS runtime-jit
WORKDIR /app
COPY openssl.cnf /etc/ssl/openssl.cnf
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf
ENV WTT_TLS_GROUP=P-256
USER $APP_UID
EXPOSE 8080 8443

FROM mcr.microsoft.com/dotnet/runtime-deps:10.0-${IMAGEBASE} AS runtime-aot
WORKDIR /app
COPY openssl.cnf /etc/ssl/openssl.cnf
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf
ENV WTT_TLS_GROUP=P-256
USER $APP_UID
EXPOSE 8080 8443

FROM runtime-aot AS runtime-true
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
COPY --from=build-aot /app/publish .
LABEL io.wtt.dotnet.native-aot="true"
LABEL io.wtt.upstream-runtime.image="${UPSTREAM_RUNTIME_IMAGE}" \
      io.wtt.upstream-runtime.digest="${UPSTREAM_RUNTIME_DIGEST}"
ENV WTT_UPSTREAM_RUNTIME_IMAGE="${UPSTREAM_RUNTIME_IMAGE}" \
    WTT_UPSTREAM_RUNTIME_DIGEST="${UPSTREAM_RUNTIME_DIGEST}"
ENTRYPOINT ["/app/dotnet10-server"]

FROM runtime-jit AS runtime-false
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
COPY --from=build /app/publish .
LABEL io.wtt.dotnet.native-aot="false"
LABEL io.wtt.upstream-runtime.image="${UPSTREAM_RUNTIME_IMAGE}" \
      io.wtt.upstream-runtime.digest="${UPSTREAM_RUNTIME_DIGEST}"
ENV WTT_UPSTREAM_RUNTIME_IMAGE="${UPSTREAM_RUNTIME_IMAGE}" \
    WTT_UPSTREAM_RUNTIME_DIGEST="${UPSTREAM_RUNTIME_DIGEST}"
ENTRYPOINT ["dotnet", "dotnet10-server.dll"]

FROM runtime-${DOTNET_AOT} AS final
USER root
# musl's separate debug file supplies native unwind tables for Alloy.
RUN if command -v apk >/dev/null 2>&1; then \
      apk info --exists 'musl=1.2.6-r2' >/dev/null || { \
        echo "ERROR: musl-dbg=1.2.6-r2 requires the matching installed musl; update the debug package pin for this base image." >&2; \
        exit 1; \
      }; \
      apk add --no-cache 'musl-dbg=1.2.6-r2'; \
    fi
USER $APP_UID
