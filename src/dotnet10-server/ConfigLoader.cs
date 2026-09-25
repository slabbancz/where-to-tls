namespace Dotnet10Server;

using System;
using System.IO;
using System.Text.Json;

public static class ConfigLoader
{
    public static ServerConfig Load(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Configuration file not found: {path}");
        }

        string json = File.ReadAllText(path);
        var config = JsonSerializer.Deserialize(json, ServerJsonContext.Default.ServerConfig)
                     ?? throw new InvalidOperationException($"Failed to deserialize configuration from {path}");

        config.Validate();
        return config;
    }
}
