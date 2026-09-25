namespace NetFx48Server
{
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Web.Script.Serialization;

    public static class ConfigLoader
    {
        private static readonly HashSet<string> AllowedTopLevel = new HashSet<string>(StringComparer.Ordinal)
        {
            "plaintextPort", "tls", "payload"
        };

        private static readonly HashSet<string> AllowedTls = new HashSet<string>(StringComparer.Ordinal)
        {
            "enabled", "port", "version", "group", "resumption", "certFile", "keyFile"
        };

        private static readonly HashSet<string> AllowedPayload = new HashSet<string>(StringComparer.Ordinal)
        {
            "preallocate"
        };

        public static string ResolveConfigPath()
        {
            string defaultPath = @"C:\wtt\config.json";
            if (!File.Exists(defaultPath) && File.Exists("/etc/wtt/config.json"))
            {
                defaultPath = "/etc/wtt/config.json";
            }

            string[] args = Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length; i++)
            {
                if (string.Equals(args[i], "--config", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    return args[i + 1];
                }
            }
            return defaultPath;
        }

        public static ServerConfig Load(string path)
        {
            if (!File.Exists(path))
            {
                throw new FileNotFoundException($"Configuration file not found: {path}");
            }

            string json = File.ReadAllText(path);
            var serializer = new JavaScriptSerializer();
            var dict = serializer.Deserialize<Dictionary<string, object>>(json) ?? throw new InvalidOperationException($"Configuration file {path} was empty or invalid JSON");
            foreach (var key in dict.Keys)
            {
                if (!AllowedTopLevel.Contains(key))
                    throw new InvalidOperationException($"Unknown config property: {key}");
            }

            var config = new ServerConfig();
            if (dict.TryGetValue("plaintextPort", out var pp) && pp != null)
                config.PlaintextPort = Convert.ToInt32(pp);

            if (dict.TryGetValue("tls", out var tlsObj) && tlsObj != null)
            {
                if (!(tlsObj is Dictionary<string, object> tlsDict))
                    throw new InvalidOperationException("Config error: 'tls' must be an object");

                foreach (var key in tlsDict.Keys)
                {
                    if (!AllowedTls.Contains(key))
                        throw new InvalidOperationException($"Unknown config property in tls: {key}");
                }

                config.Tls = new TlsOptions();
                if (tlsDict.TryGetValue("enabled", out var en) && en != null)
                    config.Tls.Enabled = Convert.ToBoolean(en);
                if (tlsDict.TryGetValue("port", out var pt) && pt != null)
                    config.Tls.Port = Convert.ToInt32(pt);
                if (tlsDict.TryGetValue("version", out var ver) && ver != null)
                    config.Tls.Version = ver.ToString()!;
                if (tlsDict.TryGetValue("group", out var group))
                    config.Tls.Group = group as string
                        ?? throw new InvalidOperationException("Config error: tls.group must be a string");
                if (tlsDict.TryGetValue("resumption", out var res) && res != null)
                    config.Tls.Resumption = Convert.ToBoolean(res);
                if (tlsDict.TryGetValue("certFile", out var certVal) && certVal != null)
                    config.Tls.CertFile = certVal.ToString()!;
                if (tlsDict.TryGetValue("keyFile", out var keyFileVal) && keyFileVal != null)
                    config.Tls.KeyFile = keyFileVal.ToString()!;
            }

            if (dict.TryGetValue("payload", out var payloadObj) && payloadObj != null)
            {
                if (!(payloadObj is Dictionary<string, object> payloadDict))
                    throw new InvalidOperationException("Config error: 'payload' must be an object");

                foreach (var key in payloadDict.Keys)
                {
                    if (!AllowedPayload.Contains(key))
                        throw new InvalidOperationException($"Unknown config property in payload: {key}");
                }

                config.Payload = new PayloadOptions();
                if (payloadDict.TryGetValue("preallocate", out var prealloc) && prealloc != null)
                    config.Payload.Preallocate = Convert.ToBoolean(prealloc);
            }

            config.Validate();
            return config;
        }
    }
}
