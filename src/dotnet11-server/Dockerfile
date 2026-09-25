# Multi-stage Dockerfile for .NET 11 server. Shared source retains endpoint and TLS parity with .NET 10.
# alpine / resolute
ARG IMAGEBASE=resolute
ARG DOTNET_AOT=false
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
FROM mcr.microsoft.com/dotnet/sdk:11.0-${IMAGEBASE} AS build
WORKDIR /src/dotnet11-server
COPY dotnet11-server/dotnet11-server.csproj ./
COPY dotnet10-server/*.cs ../dotnet10-server/
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/sdk:11.0-${IMAGEBASE}-aot AS build-aot
ARG IMAGEBASE
WORKDIR /src/dotnet11-server
COPY dotnet11-server/dotnet11-server.csproj ./
COPY dotnet10-server/*.cs ../dotnet10-server/
RUN if [ "${IMAGEBASE}" = alpine ]; then rid=linux-musl-x64; else rid=linux-x64; fi \
    && dotnet restore -r "$rid" -p:PublishAot=true \
    && dotnet publish --no-restore -r "$rid" -c Release -o /app/publish \
    -p:PublishAot=true -p:TreatWarningsAsErrors=true -p:ILLinkTreatWarningsAsErrors=true

FROM mcr.microsoft.com/dotnet/aspnet:11.0-${IMAGEBASE}  AS runtime-jit
WORKDIR /app
COPY dotnet10-server/openssl.cnf /etc/ssl/openssl.cnf
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf
ENV WTT_TLS_GROUP=P-256
USER $APP_UID
EXPOSE 8080 8443

FROM mcr.microsoft.com/dotnet/runtime-deps:11.0-${IMAGEBASE}  AS runtime-aot
WORKDIR /app
COPY dotnet10-server/openssl.cnf /etc/ssl/openssl.cnf
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf
ENV WTT_TLS_GROUP=P-256
USER $APP_UID
EXPOSE 8080 8443

FROM runtime-aot AS runtime-true
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
COPY --from=build-aot /app/publish .
LABEL io.wtt.dotnet.native-aot="true"
LABEL io.wtt.dotnet.stack="net11"
LABEL io.wtt.upstream-runtime.image="${UPSTREAM_RUNTIME_IMAGE}" \
      io.wtt.upstream-runtime.digest="${UPSTREAM_RUNTIME_DIGEST}"
ENV WTT_UPSTREAM_RUNTIME_IMAGE="${UPSTREAM_RUNTIME_IMAGE}" \
    WTT_UPSTREAM_RUNTIME_DIGEST="${UPSTREAM_RUNTIME_DIGEST}"
ENTRYPOINT ["/app/dotnet11-server"]

FROM runtime-jit AS runtime-false
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
COPY --from=build /app/publish .
LABEL io.wtt.dotnet.native-aot="false"
LABEL io.wtt.dotnet.stack="net11"
LABEL io.wtt.upstream-runtime.image="${UPSTREAM_RUNTIME_IMAGE}" \
      io.wtt.upstream-runtime.digest="${UPSTREAM_RUNTIME_DIGEST}"
ENV WTT_UPSTREAM_RUNTIME_IMAGE="${UPSTREAM_RUNTIME_IMAGE}" \
    WTT_UPSTREAM_RUNTIME_DIGEST="${UPSTREAM_RUNTIME_DIGEST}"
ENTRYPOINT ["dotnet", "dotnet11-server.dll"]

FROM runtime-${DOTNET_AOT} AS final
