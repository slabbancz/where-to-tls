namespace NetFx48Server
{
    public sealed class PayloadBuffers
    {
        private readonly byte[] _payload1K = new byte[1024];
        private readonly byte[] _payload64K = new byte[65536];
        private readonly byte[] _payload1M = new byte[1048576];
        private readonly bool _preallocate;

        public PayloadBuffers(bool preallocate)
        {
            _preallocate = preallocate;
            for (int i = 0; i < _payload1K.Length; i++) _payload1K[i] = (byte)(i % 251);
            for (int i = 0; i < _payload64K.Length; i++) _payload64K[i] = (byte)(i % 251);
            for (int i = 0; i < _payload1M.Length; i++) _payload1M[i] = (byte)(i % 251);
        }

        public byte[]? Get(string? bytesParam)
        {
            byte[]? staticBuf = bytesParam switch
            {
                "1024" => _payload1K,
                "65536" => _payload64K,
                "1048576" => _payload1M,
                _ => null
            };

            if (staticBuf == null)
                return null;

            if (_preallocate)
                return staticBuf;

            // Contract §2a secondary experiment: dynamic allocation per request
            byte[] dynamicBuf = new byte[staticBuf.Length];
            for (int i = 0; i < dynamicBuf.Length; i++)
                dynamicBuf[i] = (byte)(i % 251);
            return dynamicBuf;
        }
    }
}
