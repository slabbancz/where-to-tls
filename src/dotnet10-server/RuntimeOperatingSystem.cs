namespace Dotnet10Server;

using System;
using System.IO;
using System.Runtime.InteropServices;

internal sealed record RuntimeOperatingSystem(string Name, string Source)
{
    internal static RuntimeOperatingSystem Read()
    {
        return RuntimeInformation.IsOSPlatform(OSPlatform.Linux)
            ? ReadLinux("/etc/os-release", "/usr/lib/os-release")
            : new(RuntimeInformation.OSDescription, "RuntimeInformation.OSDescription");
    }

    internal static RuntimeOperatingSystem ReadLinux(params string[] paths)
    {
        foreach (string path in paths)
        {
            string contents;
            try
            {
                contents = File.ReadAllText(path);
            }
            catch (FileNotFoundException)
            {
                continue;
            }
            catch (DirectoryNotFoundException)
            {
                continue;
            }

            return new(contents, path);
        }

        return new("unexposed-by-runtime", "unexposed-by-runtime");
    }
}
