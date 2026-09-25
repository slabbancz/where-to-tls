package wheretotls;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;

import java.util.Map;

public final class PayloadBuffers {
    private final boolean preallocate;
    private final Map<String, byte[]> staticPayloads = Map.of(
            "1024", create(1024),
            "65536", create(65536),
            "1048576", create(1048576));

    public PayloadBuffers(boolean preallocate) {
        this.preallocate = preallocate;
    }

    public ByteBuf get(String requestedSize) {
        byte[] payload = staticPayloads.get(requestedSize);
        return payload == null ? null : Unpooled.wrappedBuffer(preallocate ? payload : create(payload.length));
    }

    private static byte[] create(int size) {
        byte[] payload = new byte[size];
        for (int index = 0; index < payload.length; index++) {
            payload[index] = (byte) (index % 251);
        }
        return payload;
    }
}
