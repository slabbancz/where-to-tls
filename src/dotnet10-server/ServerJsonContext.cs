namespace Dotnet10Server;

using System.Text.Json.Serialization;

[JsonSourceGenerationOptions(UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow)]
[JsonSerializable(typeof(ServerConfig))]
[JsonSerializable(typeof(PingResponse))]
[JsonSerializable(typeof(MetaResponse))]
internal partial class ServerJsonContext : JsonSerializerContext
{
}

public sealed record PingResponse(
    [property: JsonPropertyName("pong")] bool Pong,
    [property: JsonPropertyName("stack")] string Stack,
    [property: JsonPropertyName("host")] string Host);

public sealed record MetaResponse(
    [property: JsonPropertyName("stack")] string Stack,
    [property: JsonPropertyName("runtime_version")] string RuntimeVersion,
    [property: JsonPropertyName("upstream_runtime_image")] string UpstreamRuntimeImage,
    [property: JsonPropertyName("upstream_runtime_digest")] string UpstreamRuntimeDigest,
    [property: JsonPropertyName("tls_runtime")] string TlsRuntime,
    [property: JsonPropertyName("tls_runtime_version")] string TlsRuntimeVersion,
    [property: JsonPropertyName("server_gc")] bool ServerGc,
    [property: JsonPropertyName("os")] string Os,
    [property: JsonPropertyName("os_source")] string OsSource,
    [property: JsonPropertyName("tls_terminated_here")] bool TlsTerminatedHere,
    [property: JsonPropertyName("tls_version")] string TlsVersion,
    [property: JsonPropertyName("cipher_suite")] string CipherSuite,
    [property: JsonPropertyName("key_exchange_group")] string KeyExchangeGroup,
    [property: JsonPropertyName("tls_resumption")] bool TlsResumption,
    [property: JsonPropertyName("tls_handshake_timeout_seconds")] int TlsHandshakeTimeoutSeconds,
    [property: JsonPropertyName("http_request_timeout_seconds")] int HttpRequestTimeoutSeconds,
    [property: JsonPropertyName("http_versions")] string[] HttpVersions,
    [property: JsonPropertyName("hostname")] string Hostname,
    [property: JsonPropertyName("num_cpu")] int NumCpu,
    [property: JsonPropertyName("payload_preallocate")] bool PayloadPreallocate);
