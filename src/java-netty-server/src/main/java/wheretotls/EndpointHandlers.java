package wheretotls;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.SimpleChannelInboundHandler;
import io.netty.handler.codec.http.DefaultFullHttpResponse;
import io.netty.handler.codec.http.FullHttpRequest;
import io.netty.handler.codec.http.FullHttpResponse;
import io.netty.handler.codec.http.HttpHeaderNames;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.netty.handler.codec.http.HttpUtil;
import io.netty.handler.codec.http.HttpVersion;
import io.netty.handler.codec.http.QueryStringDecoder;

import java.nio.charset.StandardCharsets;
import java.util.List;

public final class EndpointHandlers extends SimpleChannelInboundHandler<FullHttpRequest> {
    private static final byte[] HEALTH_RESPONSE = {'o', 'k'};
    private static final byte[] INVALID_PAYLOAD_RESPONSE =
            "{\"error\":\"bytes must be one of 1024, 65536, 1048576\"}".getBytes(StandardCharsets.UTF_8);

    private final byte[] pingResponse;
    private final PayloadBuffers payloads;
    private final MetaProvider metaProvider;

    public EndpointHandlers(byte[] pingResponse, PayloadBuffers payloads, MetaProvider metaProvider) {
        this.pingResponse = pingResponse;
        this.payloads = payloads;
        this.metaProvider = metaProvider;
    }

    @Override
    protected void channelRead0(ChannelHandlerContext context, FullHttpRequest request) {
        if (!request.method().name().equals("GET")) {
            write(context, request, HttpResponseStatus.METHOD_NOT_ALLOWED, "text/plain; charset=utf-8",
                    Unpooled.copiedBuffer("Method Not Allowed", StandardCharsets.UTF_8));
            return;
        }

        QueryStringDecoder query = new QueryStringDecoder(request.uri());
        switch (query.path()) {
            case "/healthz" -> write(context, request, HttpResponseStatus.OK, "text/plain; charset=utf-8",
                    Unpooled.wrappedBuffer(HEALTH_RESPONSE));
            case "/ping" -> write(context, request, HttpResponseStatus.OK, "application/json",
                    Unpooled.wrappedBuffer(pingResponse));
            case "/payload" -> handlePayload(context, request, query);
            case "/meta" -> write(context, request, HttpResponseStatus.OK, "application/json",
                    Unpooled.wrappedBuffer(metaProvider.response(context)));
            default -> write(context, request, HttpResponseStatus.NOT_FOUND, "text/plain; charset=utf-8",
                    Unpooled.copiedBuffer("Not Found", StandardCharsets.UTF_8));
        }
    }

    private void handlePayload(ChannelHandlerContext context, FullHttpRequest request, QueryStringDecoder query) {
        List<String> values = query.parameters().get("bytes");
        String bytes = values == null || values.isEmpty() ? null : values.getFirst();
        ByteBuf payload = payloads.get(bytes);
        if (payload == null) {
            write(context, request, HttpResponseStatus.BAD_REQUEST, "application/json",
                    Unpooled.wrappedBuffer(INVALID_PAYLOAD_RESPONSE));
            return;
        }
        write(context, request, HttpResponseStatus.OK, "application/octet-stream", payload);
    }

    private static void write(ChannelHandlerContext context, FullHttpRequest request, HttpResponseStatus status,
                              String contentType, ByteBuf body) {
        FullHttpResponse response = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, status, body);
        response.headers().set(HttpHeaderNames.CONTENT_TYPE, contentType);
        response.headers().setInt(HttpHeaderNames.CONTENT_LENGTH, body.readableBytes());
        if (HttpUtil.isKeepAlive(request)) {
            context.writeAndFlush(response);
        } else {
            context.writeAndFlush(response).addListener(future -> context.close());
        }
    }
}
