package wheretotls;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelInboundHandlerAdapter;
import io.netty.channel.ChannelOutboundHandlerAdapter;
import io.netty.channel.ChannelPromise;
import io.netty.channel.DefaultChannelId;
import io.netty.channel.ServerChannel;
import io.netty.channel.SimpleChannelInboundHandler;
import io.netty.channel.embedded.EmbeddedChannel;
import io.netty.handler.codec.http.DefaultFullHttpRequest;
import io.netty.handler.codec.http.DefaultFullHttpResponse;
import io.netty.handler.codec.http.HttpMethod;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.netty.handler.codec.http.HttpVersion;
import io.netty.handler.codec.http.FullHttpRequest;
import io.netty.handler.codec.http.HttpObjectAggregator;
import io.netty.handler.codec.http2.Http2FrameCodecBuilder;
import io.netty.handler.codec.http2.Http2MultiplexHandler;
import io.netty.handler.codec.http2.Http2StreamFrameToHttpObjectCodec;
import io.netty.util.ReferenceCountUtil;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.HexFormat;

public final class HttpRequestTimeoutHandlerTest {
    public static void main(String[] args) {
        idleConnectionSurvives();
        unfinishedRequestExpires();
        completedRequestCancelsDeadline();
        blockedResponseExpires();
        pipelinedRequestKeepsItsDeadline();
        informationalResponseDoesNotCancelDeadline();
        closedConnectionCancelsDeadline();
        http2TimeoutResetsOnlyStream();
        System.out.println("HTTP request timeout tests passed");
    }

    private static final class Errors extends ChannelInboundHandlerAdapter {
        int timeouts;

        @Override
        public void exceptionCaught(ChannelHandlerContext context, Throwable cause) {
            if (!(cause instanceof TimeoutException)) {
                throw new AssertionError(cause);
            }
            timeouts++;
        }
    }

    private static final class ServerParent extends EmbeddedChannel implements ServerChannel {
    }

    private static EmbeddedChannel channel(Errors errors) {
        return new EmbeddedChannel(new HttpRequestTimeoutHandler(5, TimeUnit.SECONDS), errors);
    }

    private static void request(EmbeddedChannel channel) {
        channel.writeInbound(new DefaultFullHttpRequest(HttpVersion.HTTP_1_1, HttpMethod.GET, "/ping"));
        ReferenceCountUtil.release(channel.readInbound());
    }

    private static void response(EmbeddedChannel channel, HttpResponseStatus status) {
        channel.writeOutbound(new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, status));
        ReferenceCountUtil.release(channel.readOutbound());
    }

    private static void advance(EmbeddedChannel channel, int seconds) {
        channel.advanceTimeBy(seconds, TimeUnit.SECONDS);
        channel.runScheduledPendingTasks();
    }

    private static void require(boolean condition) {
        if (!condition) {
            throw new AssertionError("Unexpected timeout state");
        }
    }

    private static void idleConnectionSurvives() {
        Errors errors = new Errors();
        EmbeddedChannel channel = channel(errors);
        advance(channel, 30);
        require(channel.isActive() && errors.timeouts == 0);
        channel.finishAndReleaseAll();
    }

    private static void unfinishedRequestExpires() {
        Errors errors = new Errors();
        EmbeddedChannel channel = channel(errors);
        request(channel);
        advance(channel, 4);
        require(channel.isActive());
        advance(channel, 1);
        require(!channel.isActive() && errors.timeouts == 1);
        channel.finishAndReleaseAll();
    }

    private static void completedRequestCancelsDeadline() {
        Errors errors = new Errors();
        EmbeddedChannel channel = channel(errors);
        request(channel);
        response(channel, HttpResponseStatus.OK);
        advance(channel, 10);
        require(channel.isActive() && errors.timeouts == 0);
        request(channel);
        advance(channel, 5);
        require(!channel.isActive() && errors.timeouts == 1);
        channel.finishAndReleaseAll();
    }

    private static void blockedResponseExpires() {
        Errors errors = new Errors();
        ChannelPromise[] blockedWrite = new ChannelPromise[1];
        EmbeddedChannel channel = new EmbeddedChannel(new ChannelOutboundHandlerAdapter() {
            @Override
            public void write(ChannelHandlerContext context, Object message, ChannelPromise promise) {
                ReferenceCountUtil.release(message);
                blockedWrite[0] = promise;
            }
        }, new HttpRequestTimeoutHandler(5, TimeUnit.SECONDS), errors);
        request(channel);
        channel.writeOneOutbound(new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK));
        advance(channel, 5);
        require(!channel.isActive() && errors.timeouts == 1);
        blockedWrite[0].setSuccess();
        channel.finishAndReleaseAll();
    }

    private static void pipelinedRequestKeepsItsDeadline() {
        Errors errors = new Errors();
        EmbeddedChannel channel = channel(errors);
        request(channel);
        request(channel);
        response(channel, HttpResponseStatus.OK);
        advance(channel, 5);
        require(!channel.isActive() && errors.timeouts == 1);
        channel.finishAndReleaseAll();
    }

    private static void informationalResponseDoesNotCancelDeadline() {
        Errors errors = new Errors();
        EmbeddedChannel channel = channel(errors);
        request(channel);
        response(channel, HttpResponseStatus.CONTINUE);
        advance(channel, 5);
        require(!channel.isActive() && errors.timeouts == 1);
        channel.finishAndReleaseAll();
    }

    private static void closedConnectionCancelsDeadline() {
        Errors errors = new Errors();
        EmbeddedChannel channel = channel(errors);
        request(channel);
        channel.close();
        advance(channel, 10);
        require(errors.timeouts == 0);
        channel.finishAndReleaseAll();
    }

    private static void http2TimeoutResetsOnlyStream() {
        Errors errors = new Errors();
        EmbeddedChannel parent = new ServerParent();
        EmbeddedChannel channel = new EmbeddedChannel(parent, DefaultChannelId.newInstance(), true, false,
                Http2FrameCodecBuilder.forServer().build(),
                new Http2MultiplexHandler(new ChannelInitializer<Channel>() {
                    @Override
                    protected void initChannel(Channel stream) {
                        stream.pipeline().addLast(new Http2StreamFrameToHttpObjectCodec(true));
                        stream.pipeline().addLast(new HttpRequestTimeoutHandler(5, TimeUnit.SECONDS));
                        stream.pipeline().addLast(new HttpObjectAggregator(8192));
                        stream.pipeline().addLast(new SimpleChannelInboundHandler<FullHttpRequest>() {
                            @Override
                            protected void channelRead0(ChannelHandlerContext context, FullHttpRequest request) {
                                context.writeAndFlush(new DefaultFullHttpResponse(
                                        HttpVersion.HTTP_1_1, HttpResponseStatus.OK,
                                        Unpooled.buffer(1024).writeZero(1024)));
                            }
                        });
                        stream.pipeline().addLast(errors);
                    }
                }));
        // Client preface, a one-byte stream window, then a complete GET on stream 1.
        ByteBuf input = Unpooled.buffer();
        input.writeCharSequence("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", StandardCharsets.US_ASCII);
        input.writeBytes(HexFormat.of().parseHex("000006040000000000000400000001"));
        input.writeBytes(HexFormat.of().parseHex("00000e01050000000182878401096c6f63616c686f7374"));
        channel.writeInbound(input);
        advance(channel, 5);
        require(channel.isActive() && errors.timeouts == 1);

        ByteBuf output = Unpooled.buffer();
        for (ByteBuf part; (part = channel.readOutbound()) != null;) {
            output.writeBytes(part);
            part.release();
        }
        boolean reset = false;
        while (output.isReadable()) {
            int length = output.readUnsignedMedium();
            int type = output.readUnsignedByte();
            output.skipBytes(1);
            int stream = output.readInt();
            if (type == 3 && stream == 1) {
                reset = true;
            }
            output.skipBytes(length);
        }
        output.release();
        require(reset);
        channel.finishAndReleaseAll();
        parent.finishAndReleaseAll();
    }
}
