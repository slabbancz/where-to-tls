package wheretotls;

import java.nio.file.Files;
import java.nio.file.Path;

public final class ServerConfig {
    public Integer plaintextPort = 8080;
    public TlsConfig tls = new TlsConfig();
    public PayloadConfig payload = new PayloadConfig();
    public TimeoutConfig timeouts = new TimeoutConfig();

    void validate() {
        validatePort(plaintextPort, "plaintextPort");
        if (tls == null || payload == null || timeouts == null) {
            throw new IllegalArgumentException("config error: tls, payload and timeouts are required");
        }
        validateTimeout(timeouts.tlsHandshakeSeconds, "timeouts.tlsHandshakeSeconds");
        validateTimeout(timeouts.httpRequestSeconds, "timeouts.httpRequestSeconds");
        if (!tls.enabled) {
            return;
        }

        validatePort(tls.port, "tls.port");
        if (!"P-256".equals(tls.group) && !"X25519".equals(tls.group)) {
            throw new IllegalArgumentException("config error: tls.group must be P-256 or X25519");
        }
        if (!"boringssl".equals(tls.provider) && !"jdk".equals(tls.provider)) {
            throw new IllegalArgumentException("config error: tls.provider must be boringssl or jdk");
        }
        if ("jdk".equals(tls.provider) && "X25519".equals(tls.group)) {
            throw new IllegalArgumentException(
                    "config error: JDK/JSSE cannot exact-pin X25519 with the P-256 ECDSA server certificate; "
                            + "use provider boringssl for X25519 or use TLS group P-256 with provider jdk");
        }
        if (!"1.2".equals(tls.version) && !"1.3".equals(tls.version)) {
            throw new IllegalArgumentException("config error: tls.version must be exactly '1.2' or '1.3'");
        }
        if (tls.certFile == null || !Files.isRegularFile(tls.certFile)) {
            throw new IllegalArgumentException("config error: tls.certFile is not accessible");
        }
        if (tls.keyFile == null || !Files.isRegularFile(tls.keyFile)) {
            throw new IllegalArgumentException("config error: tls.keyFile is not accessible");
        }
    }

    private static void validatePort(Integer port, String name) {
        if (port == null || port <= 0 || port > 65535) {
            throw new IllegalArgumentException("config error: invalid " + name);
        }
    }

    private static void validateTimeout(Integer timeout, String name) {
        if (timeout == null || timeout < 1 || timeout > 300) {
            throw new IllegalArgumentException("config error: " + name + " must be from 1 through 300");
        }
    }

    static final class TlsConfig {
        public boolean enabled;
        public Integer port = 8443;
        public String version = "1.2";
        public String group = "P-256";
        public String provider = "boringssl";
        public boolean resumption;
        public Path certFile;
        public Path keyFile;
    }

    static final class PayloadConfig {
        public boolean preallocate = true;
    }

    static final class TimeoutConfig {
        public Integer tlsHandshakeSeconds = 5;
        public Integer httpRequestSeconds = 10;
    }
}
