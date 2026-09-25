namespace Dotnet10Server;

public static class ServerIdentity
{
#if NET11_SERVER
    public const string Stack = "net11";
#else
    public const string Stack = "net10";
#endif
}
