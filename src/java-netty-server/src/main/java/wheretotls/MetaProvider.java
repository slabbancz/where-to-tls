package wheretotls;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.handler.ssl.SslHandler;
import io.netty.handler.ssl.OpenSsl;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSession;
import java.io.IOException;
import java.security.NoSuchAlgorithmException;
import java.security.Provider;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class MetaProvider {
    private static final ObjectMapper JSON = new ObjectMapper();

    private final ServerConfig config;
    private final String hostname;

    public MetaProvider(ServerConfig config, String hostname) {
        this.config = config;
        this.hostname = hostname;
    }

    public byte[] response(ChannelHandlerContext context) {
        SSLSession session = session(context);
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("stack", "java-netty");
        meta.put("runtime_version", System.getProperty("java.runtime.version"));
        meta.put("upstream_runtime_image", requireRuntimeProvenance("WTT_UPSTREAM_RUNTIME_IMAGE"));
        meta.put("upstream_runtime_digest", requireRuntimeProvenance("WTT_UPSTREAM_RUNTIME_DIGEST"));
        TlsRuntime tlsRuntime = tlsRuntime();
        meta.put("tls_runtime", tlsRuntime.name());
        meta.put("tls_runtime_version", tlsRuntime.version());
        RuntimeOperatingSystem runtimeOS = RuntimeOperatingSystem.read();
        meta.put("os", runtimeOS.name());
        meta.put("os_source", runtimeOS.source());
        meta.put("tls_terminated_here", session != null);
        meta.put("tls_version", session == null ? "none" : tlsVersion(session.getProtocol()));
        meta.put("cipher_suite", session == null ? "none" : session.getCipherSuite());
        meta.put("key_exchange_group", session == null ? "none" : "unexposed-by-runtime");
        meta.put("tls_resumption", config.tls.resumption);
        meta.put("tls_handshake_timeout_seconds", config.timeouts.tlsHandshakeSeconds);
        meta.put("http_request_timeout_seconds", config.timeouts.httpRequestSeconds);
        meta.put("http_versions", session == null ? List.of("1.1") : List.of("1.1", "2"));
        meta.put("hostname", hostname);
        meta.put("num_cpu", Runtime.getRuntime().availableProcessors());
        meta.put("payload_preallocate", config.payload.preallocate);
        try {
            return JSON.writeValueAsBytes(meta);
        } catch (IOException exception) {
            throw new IllegalStateException("failed to encode metadata", exception);
        }
    }

    private static SSLSession session(ChannelHandlerContext context) {
        SslHandler sslHandler = context.pipeline().get(SslHandler.class);
        Channel parent = context.channel().parent();
        while (sslHandler == null && parent != null) {
            sslHandler = parent.pipeline().get(SslHandler.class);
            parent = parent.parent();
        }
        return sslHandler == null ? null : sslHandler.engine().getSession();
    }

    private static String tlsVersion(String protocol) {
        return switch (protocol) {
            case "TLSv1.2" -> "1.2";
            case "TLSv1.3" -> "1.3";
            default -> protocol;
        };
    }

    private static String requireRuntimeProvenance(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is required in the server image");
        }
        return value;
    }

    private TlsRuntime tlsRuntime() {
        return switch (config.tls.provider) {
            case "boringssl" -> boringSslRuntime();
            case "jdk" -> jdkTlsRuntime();
            default -> throw new IllegalArgumentException(
                    "tls.provider must be boringssl or jdk");
        };
    }

    private static TlsRuntime boringSslRuntime() {
        String versionString = OpenSsl.versionString();
        if (versionString == null || versionString.isBlank()) {
            throw new IllegalStateException("Netty OpenSSL provider did not report its runtime name");
        }
        String name = versionString.split("\\s+", 2)[0];
        return new TlsRuntime(name, "0x" + Long.toUnsignedString(OpenSsl.version(), 16));
    }

    private static TlsRuntime jdkTlsRuntime() {
        try {
            Provider provider = SSLContext.getDefault().getProvider();
            return new TlsRuntime(provider.getName(), provider.getVersionStr());
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("JDK TLS provider is unavailable", exception);
        }
    }

    private record TlsRuntime(String name, String version) {
    }
}
