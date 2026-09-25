namespace Dotnet10Server;

using System;
using System.Net.Security;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using Microsoft.AspNetCore.Connections.Features;
using Microsoft.AspNetCore.Http;

public sealed class MetaProvider
{
    [DllImport("libssl.so.3", EntryPoint = "OpenSSL_version", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr OpenSslVersion(int type);

    private readonly ServerConfig _config;
    private readonly string _hostname;
    private readonly bool _preallocate;

    public MetaProvider(ServerConfig config, string hostname, bool preallocate)
    {
        _config = config;
        _hostname = hostname;
        _preallocate = preallocate;
    }

    public MetaResponse GetMeta(HttpContext context)
    {
        var tlsRuntime = GetOpenSslRuntime();
        var runtimeOS = RuntimeOperatingSystem.Read();
        bool isHttps = context.Request.IsHttps;
        string tlsVersion = "none";
        string cipherSuite = "none";
        string[] httpVersions = isHttps ? new[] { "1.1", "2" } : new[] { "1.1" };

        if (isHttps)
        {
            var tlsFeature = context.Features.Get<ITlsHandshakeFeature>();
            if (tlsFeature != null)
            {
                tlsVersion = tlsFeature.Protocol switch
                {
                    SslProtocols.Tls13 => "1.3",
                    SslProtocols.Tls12 => "1.2",
                    _ => tlsFeature.Protocol.ToString()
                };
                string? cs = tlsFeature.NegotiatedCipherSuite.ToString();
                cipherSuite = string.IsNullOrEmpty(cs) ? "none" : cs;
            }
            else
            {
                throw new InvalidOperationException(
                    "Kestrel did not expose ITlsHandshakeFeature for a TLS connection."
                );
            }
        }

        string keyExchangeGroup = "none";
        if (isHttps)
        {
            // Note: .NET (SslStream/ITlsHandshakeFeature) exposes KeyExchangeAlgorithm (e.g. DiffieHellman)
            // but not the negotiated ECDHE NamedGroup/curve. Do not substitute configured policy.
            keyExchangeGroup = "unexposed-by-runtime";
        }

        return new MetaResponse(
            Stack: ServerIdentity.Stack,
            RuntimeVersion: RuntimeInformation.FrameworkDescription,
            UpstreamRuntimeImage: RequireRuntimeProvenance("WTT_UPSTREAM_RUNTIME_IMAGE"),
            UpstreamRuntimeDigest: RequireRuntimeProvenance("WTT_UPSTREAM_RUNTIME_DIGEST"),
            TlsRuntime: tlsRuntime.Name,
            TlsRuntimeVersion: tlsRuntime.Version,
            ServerGc: GCSettings.IsServerGC,
            Os: runtimeOS.Name,
            OsSource: runtimeOS.Source,
            TlsTerminatedHere: isHttps,
            TlsVersion: tlsVersion,
            CipherSuite: cipherSuite,
            KeyExchangeGroup: keyExchangeGroup,
            TlsResumption: _config.Tls?.Resumption ?? false,
            TlsHandshakeTimeoutSeconds: _config.Timeouts.TlsHandshakeSeconds,
            HttpRequestTimeoutSeconds: _config.Timeouts.HttpRequestSeconds,
            HttpVersions: httpVersions,
            Hostname: _hostname,
            NumCpu: Environment.ProcessorCount,
            PayloadPreallocate: _preallocate);
    }

    private static TlsRuntimeInfo GetOpenSslRuntime()
    {
        string? rawVersion = Marshal.PtrToStringAnsi(OpenSslVersion(0));
        if (string.IsNullOrWhiteSpace(rawVersion))
        {
            throw new InvalidOperationException("OpenSSL did not report its runtime version.");
        }

        string[] parts = rawVersion.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 2)
        {
            throw new InvalidOperationException(
                $"OpenSSL reported an unparseable runtime version: '{rawVersion}'."
            );
        }

        return new TlsRuntimeInfo(parts[0], parts[1]);
    }

    private static string RequireRuntimeProvenance(string name)
    {
        string? value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException($"{name} is required in the server image.");
        }

        return value;
    }

    private sealed record TlsRuntimeInfo(string Name, string Version);
}
