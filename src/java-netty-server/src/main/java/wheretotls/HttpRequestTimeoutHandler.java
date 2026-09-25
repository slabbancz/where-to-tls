package wheretotls;

import io.netty.channel.ChannelDuplexHandler;
import io.netty.channel.ChannelFutureListener;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.ChannelPromise;
import io.netty.handler.codec.http.FullHttpResponse;
import io.netty.handler.codec.http.HttpRequest;
import io.netty.handler.codec.http2.DefaultHttp2ResetFrame;
import io.netty.handler.codec.http2.Http2Error;
import io.netty.handler.codec.http2.Http2StreamChannel;

import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

final class HttpRequestTimeoutHandler extends ChannelDuplexHandler {
    private final long timeout;
    private final TimeUnit unit;
    private final ArrayDeque<ScheduledFuture<?>> awaitingResponse = new ArrayDeque<>();
    private final Set<ScheduledFuture<?>> pending = new HashSet<>();

    HttpRequestTimeoutHandler(long timeout, TimeUnit unit) {
        this.timeout = timeout;
        this.unit = unit;
    }

    @Override
    public void channelRead(ChannelHandlerContext context, Object message) throws Exception {
        if (message instanceof HttpRequest) {
            ScheduledFuture<?> deadline = context.executor().schedule(() -> {
                context.fireExceptionCaught(new TimeoutException("HTTP request deadline exceeded"));
                if (context.channel() instanceof Http2StreamChannel) {
                    // A queued END_STREAM can make close() alone omit the reset.
                    context.writeAndFlush(new DefaultHttp2ResetFrame(Http2Error.CANCEL))
                            .addListener(ChannelFutureListener.CLOSE);
                } else {
                    context.close();
                }
            }, timeout, unit);
            awaitingResponse.addLast(deadline);
            pending.add(deadline);
        }
        super.channelRead(context, message);
    }

    @Override
    public void write(ChannelHandlerContext context, Object message, ChannelPromise promise) throws Exception {
        // Every endpoint emits a full response; keep the deadline until its write completes.
        if (message instanceof FullHttpResponse response && response.status().code() >= 200) {
            ScheduledFuture<?> deadline = awaitingResponse.pollFirst();
            if (deadline != null) {
                promise = promise.unvoid();
                promise.addListener(future -> {
                    deadline.cancel(false);
                    pending.remove(deadline);
                });
            }
        }
        super.write(context, message, promise);
    }

    @Override
    public void channelInactive(ChannelHandlerContext context) throws Exception {
        cancelDeadlines();
        super.channelInactive(context);
    }

    @Override
    public void handlerRemoved(ChannelHandlerContext context) throws Exception {
        cancelDeadlines();
        super.handlerRemoved(context);
    }

    private void cancelDeadlines() {
        for (ScheduledFuture<?> deadline : pending) {
            deadline.cancel(false);
        }
        pending.clear();
        awaitingResponse.clear();
    }
}
