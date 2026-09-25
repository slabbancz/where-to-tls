package wheretotls;

import io.netty.handler.ssl.ApplicationProtocolConfig;
import io.netty.handler.ssl.ApplicationProtocolNames;
import io.netty.handler.ssl.OpenSslContextOption;
import io.netty.handler.ssl.OpenSsl;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.SslProvider;

import java.util.List;

public final class TlsContextFactory {

    private TlsContextFactory() {
    }

    public static SslContext create(ServerConfig.TlsConfig config) throws Exception {
        String protocol = config.version.equals("1.2") ? "TLSv1.2" : "TLSv1.3";
        String cipher = config.version.equals("1.2")
                ? "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
                : "TLS_AES_128_GCM_SHA256";

        SslContextBuilder builder = SslContextBuilder
                .forServer(config.certFile.toFile(), config.keyFile.toFile())
                .sslProvider(provider(config.provider))
                .protocols(protocol)
                .ciphers(List.of(cipher))
                .applicationProtocolConfig(new ApplicationProtocolConfig(
                        ApplicationProtocolConfig.Protocol.ALPN,
                        ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                        ApplicationProtocolConfig.SelectedListenerFailureBehavior.ACCEPT,
                        ApplicationProtocolNames.HTTP_2,
                        ApplicationProtocolNames.HTTP_1_1))
                .sessionCacheSize(config.resumption ? 20480 : 1)
                .sessionTimeout(config.resumption ? 300 : 1);

        if ("boringssl".equals(config.provider)) {
            if (!OpenSsl.isAvailable()) {
                throw new IllegalStateException(
                        "BoringSSL provider is unavailable", OpenSsl.unavailabilityCause());
            }
            builder.option(OpenSslContextOption.GROUPS, nativeGroups(config.group));
        } else {
            System.setProperty("jdk.tls.namedGroups", jdkGroups(config.group));
            System.setProperty(
                    "jdk.tls.server.enableSessionTicketExtension",
                    Boolean.toString(config.resumption));
        }

        return builder.build();
    }

    private static SslProvider provider(String name) {
        return switch (name) {
            case "boringssl" -> SslProvider.OPENSSL;
            case "jdk" -> SslProvider.JDK;
            default -> throw new IllegalArgumentException("tls.provider must be boringssl or jdk");
        };
    }

    private static String[] nativeGroups(String group) {
        return switch (group) {
            case "P-256" -> new String[]{"P-256"};
            case "X25519" -> new String[]{"X25519"};
            default -> throw new IllegalArgumentException("tls.group must be P-256 or X25519");
        };
    }

    private static String jdkGroups(String group) {
        return switch (group) {
            case "P-256" -> "secp256r1";
            case "X25519" -> "x25519";
            default -> throw new IllegalArgumentException("tls.group must be P-256 or X25519");
        };
    }
}
