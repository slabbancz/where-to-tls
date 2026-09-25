package wheretotls;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelOption;
import io.netty.channel.ChannelPipeline;
import io.netty.channel.EventLoopGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http.HttpObjectAggregator;
import io.netty.handler.codec.http.HttpServerCodec;
import io.netty.handler.codec.http2.Http2FrameCodecBuilder;
import io.netty.handler.codec.http2.Http2MultiplexHandler;
import io.netty.handler.codec.http2.Http2StreamFrameToHttpObjectCodec;
import io.netty.handler.ssl.ApplicationProtocolNegotiationHandler;
import io.netty.handler.ssl.ApplicationProtocolNames;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslHandler;

import java.io.IOException;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.TimeUnit;

public final class NettyServer {
    private static final int MAX_REQUEST_BYTES = 8 * 1024;
    private static final ObjectMapper JSON = new ObjectMapper();

    private final ServerConfig config;
    private final RequestHandlerFactory handlers;

    public NettyServer(ServerConfig config) {
        this.config = config;
        String hostname = System.getenv().getOrDefault("HOSTNAME", "localhost");
        byte[] pingResponse = pingResponse(hostname);
        this.handlers = new RequestHandlerFactory(
                pingResponse,
                new PayloadBuffers(config.payload.preallocate),
                new MetaProvider(config, hostname));
    }

    public void run() throws Exception {
        EventLoopGroup bossGroup = new NioEventLoopGroup(1);
        EventLoopGroup workerGroup = new NioEventLoopGroup();
        try {
            SslContext tlsContext = config.tls.enabled ? TlsContextFactory.create(config.tls) : null;
            Channel plain = bind(bossGroup, workerGroup, config.plaintextPort, null);
            Channel tls = tlsContext == null ? null : bind(bossGroup, workerGroup, config.tls.port, tlsContext);
            System.err.printf("[java-netty-server] starting plaintext=:%d tls=:%d preallocate=%s%n",
                    config.plaintextPort, tls == null ? 0 : config.tls.port, config.payload.preallocate);
            waitForShutdown(plain, tls);
        } finally {
            bossGroup.shutdownGracefully().sync();
            workerGroup.shutdownGracefully().sync();
        }
    }

    private Channel bind(EventLoopGroup bossGroup, EventLoopGroup workerGroup, int port, SslContext tlsContext)
            throws InterruptedException {
        return new ServerBootstrap()
                .group(bossGroup, workerGroup)
                .channel(NioServerSocketChannel.class)
                .childOption(ChannelOption.TCP_NODELAY, true)
                .childOption(ChannelOption.SO_KEEPALIVE, true)
                .childHandler(new PipelineInitializer(
                        tlsContext,
                        handlers,
                        config.timeouts.tlsHandshakeSeconds,
                        config.timeouts.httpRequestSeconds))
                .bind(port)
                .sync()
                .channel();
    }

    private static void waitForShutdown(Channel plain, Channel tls) throws InterruptedException {
        AtomicBoolean shuttingDown = new AtomicBoolean();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            if (shuttingDown.compareAndSet(false, true)) {
                System.err.println("[java-netty-server] shutting down");
                plain.close();
                if (tls != null) {
                    tls.close();
                }
            }
        }));
        if (tls != null) {
            tls.closeFuture().addListener(ignored -> plain.close());
        }
        plain.closeFuture().sync();
    }

    private static byte[] pingResponse(String hostname) {
        try {
            return JSON.writeValueAsBytes(Map.of("pong", true, "stack", "java-netty", "host", hostname));
        } catch (IOException exception) {
            throw new IllegalStateException("failed to encode ping response", exception);
        }
    }

    private record RequestHandlerFactory(byte[] pingResponse, PayloadBuffers payloads, MetaProvider metaProvider) {
        private EndpointHandlers create() {
            return new EndpointHandlers(pingResponse, payloads, metaProvider);
        }
    }

    private static final class PipelineInitializer extends ChannelInitializer<SocketChannel> {
        private final SslContext tlsContext;
        private final RequestHandlerFactory handlers;
        private final int tlsHandshakeTimeoutSeconds;
        private final int httpRequestTimeoutSeconds;

        private PipelineInitializer(
                SslContext tlsContext,
                RequestHandlerFactory handlers,
                int tlsHandshakeTimeoutSeconds,
                int httpRequestTimeoutSeconds) {
            this.tlsContext = tlsContext;
            this.handlers = handlers;
            this.tlsHandshakeTimeoutSeconds = tlsHandshakeTimeoutSeconds;
            this.httpRequestTimeoutSeconds = httpRequestTimeoutSeconds;
        }

        @Override
        protected void initChannel(SocketChannel channel) {
            ChannelPipeline pipeline = channel.pipeline();
            if (tlsContext == null) {
                configureHttp1(pipeline, handlers, httpRequestTimeoutSeconds);
                return;
            }
            SslHandler sslHandler = tlsContext.newHandler(channel.alloc());
            sslHandler.setHandshakeTimeout(tlsHandshakeTimeoutSeconds, TimeUnit.SECONDS);
            pipeline.addLast(sslHandler);
            pipeline.addLast(new AlpnHandler(handlers, httpRequestTimeoutSeconds));
        }
    }

    private static final class AlpnHandler extends ApplicationProtocolNegotiationHandler {
        private final RequestHandlerFactory handlers;
        private final int httpRequestTimeoutSeconds;

        private AlpnHandler(RequestHandlerFactory handlers, int httpRequestTimeoutSeconds) {
            super(ApplicationProtocolNames.HTTP_1_1);
            this.handlers = handlers;
            this.httpRequestTimeoutSeconds = httpRequestTimeoutSeconds;
        }

        @Override
        protected void configurePipeline(ChannelHandlerContext context, String protocol) {
            if (ApplicationProtocolNames.HTTP_2.equals(protocol)) {
                context.pipeline().addLast(Http2FrameCodecBuilder.forServer().build());
                context.pipeline().addLast(new Http2MultiplexHandler(new ChannelInitializer<Channel>() {
                    @Override
                    protected void initChannel(Channel stream) {
                        stream.pipeline().addLast(new Http2StreamFrameToHttpObjectCodec(true));
                        stream.pipeline().addLast(
                                new HttpRequestTimeoutHandler(httpRequestTimeoutSeconds, TimeUnit.SECONDS));
                        stream.pipeline().addLast(new HttpObjectAggregator(MAX_REQUEST_BYTES));
                        stream.pipeline().addLast(handlers.create());
                    }
                }));
                return;
            }
            if (ApplicationProtocolNames.HTTP_1_1.equals(protocol)) {
                configureHttp1(context.pipeline(), handlers, httpRequestTimeoutSeconds);
                return;
            }
            throw new IllegalStateException("unsupported ALPN protocol: " + protocol);
        }
    }

    private static void configureHttp1(
            ChannelPipeline pipeline, RequestHandlerFactory handlers, int httpRequestTimeoutSeconds) {
        pipeline.addLast(new HttpServerCodec());
        pipeline.addLast(new HttpRequestTimeoutHandler(httpRequestTimeoutSeconds, TimeUnit.SECONDS));
        pipeline.addLast(new HttpObjectAggregator(MAX_REQUEST_BYTES));
        pipeline.addLast(handlers.create());
    }
}
