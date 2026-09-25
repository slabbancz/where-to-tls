# Eclipse Temurin 25 is intentionally pinned by release tag; mutable and digest-only references are forbidden.
ARG IMAGEBASE=resolute
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
FROM docker.io/library/eclipse-temurin:25.0.4_7-jdk-${IMAGEBASE} AS build

ARG MAVEN_VERSION=3.9.11
WORKDIR /src

RUN if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache curl ca-certificates; \
    else \
        apt-get update \
        && apt-get install -y --no-install-recommends curl ca-certificates \
        && rm -rf /var/lib/apt/lists/*; \
    fi \
    && curl --fail --location --silent --show-error \
      "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      -o /opt/apache-maven.tar.gz \
    && tar -xzf /opt/apache-maven.tar.gz -C /opt \
    && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn \
    && rm /opt/apache-maven.tar.gz

COPY pom.xml ./
COPY src ./src
RUN mvn --batch-mode --no-transfer-progress package -DskipTests

FROM docker.io/library/eclipse-temurin:25.0.4_7-jre-${IMAGEBASE}
ARG UPSTREAM_RUNTIME_IMAGE
ARG UPSTREAM_RUNTIME_DIGEST
WORKDIR /app
RUN if command -v apk >/dev/null 2>&1; then \
        addgroup -S wtt \
        && adduser -S -D -H -G wtt -h /app -s /sbin/nologin wtt; \
    else \
        groupadd --system wtt \
        && useradd --system --gid wtt --home-dir /app --shell /usr/sbin/nologin wtt; \
    fi \
    && mkdir -p /etc/wtt
COPY --from=build /src/target/java-netty-server-1.0.0.jar /app/server.jar

LABEL io.wtt.upstream-runtime.image="${UPSTREAM_RUNTIME_IMAGE}" \
      io.wtt.upstream-runtime.digest="${UPSTREAM_RUNTIME_DIGEST}"
ENV WTT_UPSTREAM_RUNTIME_IMAGE="${UPSTREAM_RUNTIME_IMAGE}" \
    WTT_UPSTREAM_RUNTIME_DIGEST="${UPSTREAM_RUNTIME_DIGEST}"
USER wtt:wtt
EXPOSE 8080 8443
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/server.jar"]
