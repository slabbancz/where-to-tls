namespace Dotnet10Server;

using System;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http.Timeouts;
using Microsoft.AspNetCore.Server.Kestrel.Core;

public static class Program
{
    public static async Task Main(string[] args)
    {
        string configPath = "/etc/wtt/config.json";
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--config" && i + 1 < args.Length)
            {
                configPath = args[i + 1];
                break;
            }
        }

        ServerConfig cfg;
        try
        {
            cfg = ConfigLoader.Load(configPath);
            Console.Error.WriteLine($"[{ServerIdentity.Stack}-server] Loaded configuration from {configPath}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[{ServerIdentity.Stack}-server] FATAL: Invalid configuration: {ex.Message}");
            Environment.Exit(1);
            return;
        }

        string hostname = Environment.MachineName;
        if (string.IsNullOrEmpty(hostname))
        {
            hostname = "localhost";
        }

        bool preallocate = cfg.Payload?.Preallocate ?? true;
        var payloads = new PayloadBuffers(preallocate);
        var metaProvider = new MetaProvider(cfg, hostname, preallocate);
        var handlers = new EndpointHandlers(cfg, hostname, payloads, metaProvider);

#if NATIVE_AOT
        var builder = WebApplication.CreateSlimBuilder(args);
        builder.WebHost.UseKestrelHttpsConfiguration();
#else
        var builder = WebApplication.CreateBuilder(args);
#endif
        builder.Logging.ClearProviders();
        builder.Services.AddRequestTimeouts(options =>
        {
            options.DefaultPolicy = new RequestTimeoutPolicy
            {
                Timeout = TimeSpan.FromSeconds(cfg.Timeouts.HttpRequestSeconds)
            };
        });

        builder.WebHost.ConfigureKestrel(options =>
        {
            options.Limits.KeepAliveTimeout = TimeSpan.FromMinutes(2);
            options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(cfg.Timeouts.HttpRequestSeconds);

            // Plaintext listener: HTTP/1.1 only
            options.ListenAnyIP(cfg.PlaintextPort, listenOptions =>
            {
                listenOptions.Protocols = HttpProtocols.Http1;
            });

            // TLS listener: HTTP/1.1 and HTTP/2
            if (cfg.Tls != null && cfg.Tls.Enabled)
            {
                var serverCert = X509Certificate2.CreateFromPemFile(cfg.Tls.CertFile, cfg.Tls.KeyFile);
                bool resume = cfg.Tls.Resumption;

                // Contract §2a & §3: Explicit switch with hard throw on anything other than "1.2" or "1.3"
                SslProtocols sslProtocols = cfg.Tls.Version switch
                {
                    "1.2" => SslProtocols.Tls12,
                    "1.3" => SslProtocols.Tls13,
                    _ => throw new InvalidOperationException(
                        $"Unsupported TLS version '{cfg.Tls.Version}'. Must be exactly '1.2' or '1.3' (Contract §3)."
                    )
                };

                // Build the policy once: its Linux constructor allocates native OpenSSL objects.
                // Curve pinning remains in openssl.cnf; this API is unsupported on Windows.
                CipherSuitesPolicy? cipherSuitesPolicy = null;
                if (OperatingSystem.IsLinux())
                {
                    cipherSuitesPolicy = new CipherSuitesPolicy(new[]
                    {
                        sslProtocols == SslProtocols.Tls12
                            ? TlsCipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
                            : TlsCipherSuite.TLS_AES_128_GCM_SHA256
                    });
                }

                options.ListenAnyIP(cfg.Tls.Port, listenOptions =>
                {
                    listenOptions.Protocols = HttpProtocols.Http1AndHttp2;
                    listenOptions.UseHttps(httpsOptions =>
                    {
                        httpsOptions.ServerCertificate = serverCert;
                        httpsOptions.SslProtocols = sslProtocols;
                        httpsOptions.HandshakeTimeout = TimeSpan.FromSeconds(cfg.Timeouts.TlsHandshakeSeconds);
                        httpsOptions.OnAuthenticate = (_, authOptions) =>
                        {
                            authOptions.EnabledSslProtocols = sslProtocols;
                            authOptions.AllowTlsResume = resume;
                            authOptions.AllowRenegotiation = false; // Contract §3: TLS renegotiation disabled

                            if (cipherSuitesPolicy != null)
                            {
                                authOptions.CipherSuitesPolicy = cipherSuitesPolicy;
                            }
                        };
                    });
                });
            }
        });

        var app = builder.Build();
        app.UseRouting();
        app.UseRequestTimeouts();

        app.MapGet("/ping", handlers.HandlePingAsync);
        app.MapGet("/payload", handlers.HandlePayloadAsync);
        app.MapGet("/healthz", handlers.HandleHealthzAsync);
        app.MapGet("/meta", handlers.HandleMetaAsync);

        int tlsPortLogged = (cfg.Tls != null && cfg.Tls.Enabled) ? cfg.Tls.Port : 0;
        Console.Error.WriteLine($"[{ServerIdentity.Stack}-server] starting plaintext=:{cfg.PlaintextPort} tls=:{tlsPortLogged} preallocate={preallocate} nativeAot={!System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported}");

        await app.RunAsync();

        Console.Error.WriteLine($"[{ServerIdentity.Stack}-server] shutting down");
    }
}
