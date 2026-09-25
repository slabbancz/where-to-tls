namespace NetFx48Server
{
    using System;
    using System.Runtime.InteropServices;
    using System.Web;
    using System.Web.Script.Serialization;

    public sealed class MetaProvider
    {
        private readonly ServerConfig _config;
        private readonly string _hostname;
        private readonly bool _preallocate;
        private readonly string _runtimeVersion;

        public MetaProvider(ServerConfig config, string hostname, bool preallocate)
        {
            _config = config;
            _hostname = hostname;
            _preallocate = preallocate;
            _runtimeVersion = RuntimeInformation.FrameworkDescription;
        }

        public byte[] GetMetaJsonBytes(HttpContext context)
        {
            bool isHttps = context.Request.IsSecureConnection;
            string tlsVersion = "none";
            string cipherSuite = "none";
            string[] httpVersions = new[] { "1.1" };

            string keyExchangeGroup = "none";
            if (isHttps)
            {
                tlsVersion = _config.Tls?.Version ?? "1.2";
                cipherSuite = "unexposed-by-runtime";
                keyExchangeGroup = "unexposed-by-runtime";
                httpVersions = new[] { "1.1", "2" };
            }

            var serializer = new JavaScriptSerializer();
            string json = serializer.Serialize(new
            {
                stack = "netfx48",
                runtime_version = _runtimeVersion,
                upstream_runtime_image = "not-applicable",
                upstream_runtime_digest = "not-applicable",
                tls_runtime = "unexposed-by-runtime",
                tls_runtime_version = "unexposed-by-runtime",
                os = RuntimeInformation.OSDescription,
                os_source = "RuntimeInformation.OSDescription",
                tls_terminated_here = isHttps,
                tls_version = tlsVersion,
                cipher_suite = cipherSuite,
                key_exchange_group = keyExchangeGroup,
                http_versions = httpVersions,
                hostname = _hostname,
                num_cpu = Environment.ProcessorCount,
                payload_preallocate = _preallocate
            });

            return System.Text.Encoding.UTF8.GetBytes(json);
        }
    }
}
