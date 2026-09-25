namespace Dotnet10Server;

using System;
using System.IO;
using System.Text.Json.Serialization;

public sealed class TlsOptions
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("port")]
    public int Port { get; set; } = 8443;

    [JsonPropertyName("version")]
    public string Version { get; set; } = "1.2";

    [JsonPropertyName("group")]
    public string Group { get; set; } = "P-256";

    [JsonPropertyName("resumption")]
    public bool Resumption { get; set; } = false;

    [JsonPropertyName("certFile")]
    public string CertFile { get; set; } = "/etc/wtt/tls/tls.crt";

    [JsonPropertyName("keyFile")]
    public string KeyFile { get; set; } = "/etc/wtt/tls/tls.key";
}

public sealed class PayloadOptions
{
    [JsonPropertyName("preallocate")]
    public bool Preallocate { get; set; } = true;
}

public sealed class TimeoutOptions
{
    [JsonPropertyName("tlsHandshakeSeconds")]
    public int TlsHandshakeSeconds { get; set; } = 5;

    [JsonPropertyName("httpRequestSeconds")]
    public int HttpRequestSeconds { get; set; } = 10;

    public void Validate()
    {
        if (TlsHandshakeSeconds is < 1 or > 300)
            throw new ArgumentException("Config error: timeouts.tlsHandshakeSeconds must be from 1 through 300.");
        if (HttpRequestSeconds is < 1 or > 300)
            throw new ArgumentException("Config error: timeouts.httpRequestSeconds must be from 1 through 300.");
    }
}

public sealed class ServerConfig
{
    [JsonPropertyName("plaintextPort")]
    public int PlaintextPort { get; set; } = 8080;

    [JsonPropertyName("tls")]
    public TlsOptions? Tls { get; set; }

    [JsonPropertyName("payload")]
    public PayloadOptions? Payload { get; set; }

    [JsonPropertyName("timeouts")]
    public TimeoutOptions Timeouts { get; set; } = new();

    public void Validate()
    {
        if (PlaintextPort <= 0 || PlaintextPort > 65535)
            throw new ArgumentException($"Config error: invalid plaintextPort {PlaintextPort}");

        if (Tls != null && Tls.Enabled)
        {
            if (Tls.Group != "P-256" && Tls.Group != "X25519")
                throw new ArgumentException("Config error: tls.group must be P-256 or X25519.");
            if (Tls.Port <= 0 || Tls.Port > 65535)
                throw new ArgumentException($"Config error: invalid tls.port {Tls.Port}");
            if (Tls.Version != "1.2" && Tls.Version != "1.3")
                throw new ArgumentException($"Config error: invalid tls.version '{Tls.Version}'. Must be exactly '1.2' or '1.3' (Contract §3).");
            if (string.IsNullOrWhiteSpace(Tls.CertFile))
                throw new ArgumentException("Config error: tls.certFile cannot be empty");
            if (!File.Exists(Tls.CertFile))
                throw new FileNotFoundException($"Config error: tls.certFile '{Tls.CertFile}' not found");
            if (string.IsNullOrWhiteSpace(Tls.KeyFile))
                throw new ArgumentException("Config error: tls.keyFile cannot be empty");
            if (!File.Exists(Tls.KeyFile))
                throw new FileNotFoundException($"Config error: tls.keyFile '{Tls.KeyFile}' not found");
            TlsGroupPolicy.Validate(Tls.Group);
        }
        Timeouts.Validate();
    }
}
