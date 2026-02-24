using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Microsoft.AspNet.SignalR;
using Microsoft.Owin;
using Microsoft.Owin.Cors;
using Owin;

namespace SignalRServer
{
    public class Startup
    {
        public void Configuration(IAppBuilder app)
        {
            try
            {
                Debug.WriteLine("[Startup] Configuration starting...");

                // CORS - allow Angular client on different port
                app.UseCors(CorsOptions.AllowAll);

                // SignalR configuration
                var hubConfig = new HubConfiguration
                {
                    EnableDetailedErrors = true,
                    EnableJSONP = false
                };

                // Global SignalR settings
                GlobalHost.Configuration.ConnectionTimeout = TimeSpan.FromSeconds(30);
                GlobalHost.Configuration.DisconnectTimeout = TimeSpan.FromSeconds(15);
                GlobalHost.Configuration.KeepAlive = TimeSpan.FromSeconds(5);
                GlobalHost.Configuration.TransportConnectTimeout = TimeSpan.FromSeconds(10);

                // Map SignalR - handles HTTPS and WSS
                app.MapSignalR(hubConfig);

                Debug.WriteLine("[Startup] Configuration completed successfully.");
                Debug.WriteLine($"[Startup] DisconnectTimeout: {GlobalHost.Configuration.DisconnectTimeout.TotalSeconds}s");
                Debug.WriteLine($"[Startup] KeepAlive: {GlobalHost.Configuration.KeepAlive?.TotalSeconds}s");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Startup] ERROR: {ex}");
                throw;
            }
        }
    }
}
