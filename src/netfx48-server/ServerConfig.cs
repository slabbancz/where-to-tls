namespace NetFx48Server
{
    using System;

    public sealed class TlsOptions
    {
        public bool Enabled { get; set; } = true;
        public int Port { get; set; } = 8443;
        public string Version { get; set; } = "1.2";
        public string Group { get; set; } = "P-256";
        public bool Resumption { get; set; } = false;
        public string CertFile { get; set; } = @"C:\wtt\tls\tls.crt";
        public string KeyFile { get; set; } = @"C:\wtt\tls\tls.key";
    }

    public sealed class PayloadOptions
    {
        public bool Preallocate { get; set; } = true;
    }

    public sealed class ServerConfig
    {
        public int PlaintextPort { get; set; } = 8080;
        public TlsOptions? Tls { get; set; }
        public PayloadOptions? Payload { get; set; }

        public void Validate()
        {
            if (PlaintextPort <= 0 || PlaintextPort > 65535)
                throw new ArgumentException($"Config error: invalid plaintextPort {PlaintextPort}");

            if (Tls != null && Tls.Enabled)
            {
                if (Tls.Port <= 0 || Tls.Port > 65535)
                    throw new ArgumentException($"Config error: invalid tls.port {Tls.Port}");
                if (Environment.OSVersion.Platform != PlatformID.Win32NT || Tls.Version != "1.2")
                    throw new ArgumentException("Config error: netfx48 requires Windows Schannel and TLS 1.2.");
                if (Tls.Group != "P-256" && Tls.Group != "X25519")
                    throw new ArgumentException("Config error: tls.group must be P-256 or X25519.");
            }
        }
    }
}
