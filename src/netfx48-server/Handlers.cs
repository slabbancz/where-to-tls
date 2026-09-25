using System;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

namespace NetFx48Server
{
    internal static class ServerContext
    {
        public static readonly ServerConfig Config;
        public static readonly string Hostname;
        public static readonly byte[] PrecomputedPingBytes;
        public static readonly PayloadBuffers Buffers;
        public static readonly MetaProvider Meta;

        static ServerContext()
        {
            string configPath = ConfigLoader.ResolveConfigPath();
            Config = ConfigLoader.Load(configPath);

            Hostname = Environment.MachineName;
            if (string.IsNullOrEmpty(Hostname))
            {
                Hostname = "localhost";
            }

            bool preallocate = Config.Payload?.Preallocate ?? true;
            Buffers = new PayloadBuffers(preallocate);
            Meta = new MetaProvider(Config, Hostname, preallocate);

            var serializer = new JavaScriptSerializer();
            string json = serializer.Serialize(new
            {
                pong = true,
                stack = "netfx48",
                host = Hostname
            });
            PrecomputedPingBytes = Encoding.UTF8.GetBytes(json);
        }
    }

    public class PingHandler : IHttpHandler
    {
        public bool IsReusable => true;

        public void ProcessRequest(HttpContext context)
        {
            if (!string.Equals(context.Request.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase))
            {
                context.Response.StatusCode = 405;
                return;
            }

            context.Response.ContentType = "application/json";
            context.Response.OutputStream.Write(ServerContext.PrecomputedPingBytes, 0, ServerContext.PrecomputedPingBytes.Length);
        }
    }

    public class PayloadHandler : IHttpHandler
    {
        public bool IsReusable => true;

        public void ProcessRequest(HttpContext context)
        {
            if (!string.Equals(context.Request.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase))
            {
                context.Response.StatusCode = 405;
                return;
            }

            string? bytesParam = context.Request.QueryString["bytes"];
            byte[]? buf = ServerContext.Buffers.Get(bytesParam);

            if (buf == null)
            {
                context.Response.StatusCode = 400;
                context.Response.ContentType = "application/json";
                byte[] err = Encoding.UTF8.GetBytes("{\"error\":\"bytes must be one of 1024, 65536, 1048576\"}");
                context.Response.OutputStream.Write(err, 0, err.Length);
                return;
            }

            context.Response.ContentType = "application/octet-stream";
            context.Response.Headers["Content-Length"] = buf.Length.ToString();
            context.Response.OutputStream.Write(buf, 0, buf.Length);
        }
    }

    public class HealthzHandler : IHttpHandler
    {
        public bool IsReusable => true;

        public void ProcessRequest(HttpContext context)
        {
            if (!string.Equals(context.Request.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase))
            {
                context.Response.StatusCode = 405;
                return;
            }

            context.Response.ContentType = "text/plain; charset=utf-8";
            byte[] ok = Encoding.UTF8.GetBytes("ok");
            context.Response.OutputStream.Write(ok, 0, ok.Length);
        }
    }

    public class MetaHandler : IHttpHandler
    {
        public bool IsReusable => true;

        public void ProcessRequest(HttpContext context)
        {
            if (!string.Equals(context.Request.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase))
            {
                context.Response.StatusCode = 405;
                return;
            }

            byte[] respBytes = ServerContext.Meta.GetMetaJsonBytes(context);
            context.Response.ContentType = "application/json";
            context.Response.OutputStream.Write(respBytes, 0, respBytes.Length);
        }
    }
}
