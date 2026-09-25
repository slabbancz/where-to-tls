namespace Dotnet10Server;

using System;
using System.IO;
using System.Linq;

public static class TlsGroupPolicy
{
    public static void Validate(string group)
    {
        if (!OperatingSystem.IsLinux())
            throw new PlatformNotSupportedException("Pinned TLS groups in .NET 10/11 require Linux/OpenSSL.");
        if (Environment.GetEnvironmentVariable("WTT_TLS_GROUP") != group)
            throw new InvalidOperationException("Start the process with WTT_TLS_GROUP matching tls.group.");
        string? path = Environment.GetEnvironmentVariable("OPENSSL_CONF");
        if (string.IsNullOrEmpty(path))
            throw new InvalidOperationException("OPENSSL_CONF must point to the WTT openssl.cnf before process startup.");

        // Reject overrides/includes: an environment label alone does not restrict OpenSSL.
        string actual = string.Join("\n", File.ReadLines(path).Select(line => line.Trim())
            .Where(line => line.Length > 0 && !line.StartsWith('#')));
        const string expected = "openssl_conf = default_conf\n[default_conf]\nssl_conf = ssl_sect\n" +
            "[ssl_sect]\nsystem_default = system_default_sect\n[system_default_sect]\nGroups = $ENV::WTT_TLS_GROUP";
        if (actual != expected)
            throw new InvalidOperationException("OPENSSL_CONF must use the unmodified WTT group policy.");
    }
}
