namespace Dotnet10Server;

using System.Net;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

public sealed class EndpointHandlers
{
    private readonly byte[] _precomputedPingBytes;
    private readonly PayloadBuffers _payloads;
    private readonly MetaProvider _metaProvider;

    public EndpointHandlers(ServerConfig config, string hostname, PayloadBuffers payloads, MetaProvider metaProvider)
    {
        _payloads = payloads;
        _metaProvider = metaProvider;

        var pingJson = JsonSerializer.Serialize(
            new PingResponse(true, ServerIdentity.Stack, hostname), ServerJsonContext.Default.PingResponse);
        _precomputedPingBytes = System.Text.Encoding.UTF8.GetBytes(pingJson);
    }

    public async Task HandlePingAsync(HttpContext context)
    {
        context.Response.StatusCode = (int)HttpStatusCode.OK;
        context.Response.ContentType = "application/json";
        context.Response.ContentLength = _precomputedPingBytes.Length;
        await context.Response.Body.WriteAsync(_precomputedPingBytes, context.RequestAborted);
    }

    public async Task HandlePayloadAsync(HttpContext context)
    {
        string? bytesParam = context.Request.Query["bytes"];
        byte[]? buf = _payloads.Get(bytesParam);
        if (buf == null)
        {
            context.Response.StatusCode = (int)HttpStatusCode.BadRequest;
            context.Response.ContentType = "application/json";
            await context.Response.WriteAsync("{\"error\":\"bytes must be one of 1024, 65536, 1048576\"}", context.RequestAborted);
            return;
        }

        context.Response.StatusCode = (int)HttpStatusCode.OK;
        context.Response.ContentType = "application/octet-stream";
        context.Response.ContentLength = buf.Length;
        await context.Response.Body.WriteAsync(buf, context.RequestAborted);
    }

    public async Task HandleHealthzAsync(HttpContext context)
    {
        context.Response.StatusCode = (int)HttpStatusCode.OK;
        context.Response.ContentType = "text/plain; charset=utf-8";
        await context.Response.WriteAsync("ok", context.RequestAborted);
    }

    public async Task HandleMetaAsync(HttpContext context)
    {
        var meta = _metaProvider.GetMeta(context);
        context.Response.StatusCode = (int)HttpStatusCode.OK;
        context.Response.ContentType = "application/json";
        await context.Response.WriteAsync(
            JsonSerializer.Serialize(meta, ServerJsonContext.Default.MetaResponse), context.RequestAborted);
    }
}
