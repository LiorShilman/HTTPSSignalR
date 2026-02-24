using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Threading.Tasks;
using System.Timers;
using Microsoft.AspNet.SignalR;

namespace SignalRServer
{
    /// <summary>
    /// Client info tracked on the server
    /// </summary>
    public class ClientInfo
    {
        public string ConnectionId { get; set; }
        public string Transport { get; set; }
        public DateTime ConnectedAt { get; set; }
        public DateTime LastHeartbeat { get; set; }
        public string ClientName { get; set; }
        public int HeartbeatsMissed { get; set; }
    }

    public class StatusHub : Hub
    {
        // Thread-safe dictionary of all connected clients
        private static readonly ConcurrentDictionary<string, ClientInfo> _clients
            = new ConcurrentDictionary<string, ClientInfo>();

        // Server-side heartbeat timer (checks client liveness)
        private static Timer _heartbeatTimer;
        private static readonly object _timerLock = new object();
        private const int HEARTBEAT_INTERVAL_MS = 10000;  // 10 seconds
        private const int MAX_MISSED_HEARTBEATS = 3;

        static StatusHub()
        {
            StartHeartbeatTimer();
        }

        #region Connection Lifecycle

        public override Task OnConnected()
        {
            var transport = Context.QueryString["transport"] ?? "unknown";

            var clientInfo = new ClientInfo
            {
                ConnectionId = Context.ConnectionId,
                Transport = transport,
                ConnectedAt = DateTime.Now,
                LastHeartbeat = DateTime.Now,
                ClientName = Context.QueryString["clientName"] ?? Context.ConnectionId.Substring(0, 8),
                HeartbeatsMissed = 0
            };

            _clients.TryAdd(Context.ConnectionId, clientInfo);

            NotifyUI($"[+] Client connected: {clientInfo.ClientName} | Transport: {transport} | ID: {Context.ConnectionId}");
            UpdateUIClientList();

            // Notify the connecting client
            base.Clients.Caller.onConnected(new
            {
                connectionId = Context.ConnectionId,
                serverTime = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"),
                heartbeatInterval = HEARTBEAT_INTERVAL_MS,
                message = "Connected successfully"
            });

            // Notify all other clients about new connection
            base.Clients.Others.onClientJoined(new
            {
                clientName = clientInfo.ClientName,
                transport = transport,
                totalClients = _clients.Count
            });

            return base.OnConnected();
        }

        public override Task OnDisconnected(bool stopCalled)
        {
            ClientInfo removed;
            if (_clients.TryRemove(Context.ConnectionId, out removed))
            {
                var duration = DateTime.Now - removed.ConnectedAt;
                NotifyUI($"[-] Client disconnected: {removed.ClientName} | Duration: {duration:hh\\:mm\\:ss} | StopCalled: {stopCalled}");

                // Notify remaining clients
                base.Clients.All.onClientLeft(new
                {
                    clientName = removed.ClientName,
                    totalClients = _clients.Count
                });
            }

            UpdateUIClientList();
            return base.OnDisconnected(stopCalled);
        }

        public override Task OnReconnected()
        {
            ClientInfo existing;
            if (_clients.TryGetValue(Context.ConnectionId, out existing))
            {
                existing.LastHeartbeat = DateTime.Now;
                existing.HeartbeatsMissed = 0;
                NotifyUI($"[~] Client reconnected: {existing.ClientName} | ID: {Context.ConnectionId}");
            }
            else
            {
                // Reconnected but wasn't tracked - re-add
                var clientInfo = new ClientInfo
                {
                    ConnectionId = Context.ConnectionId,
                    Transport = Context.QueryString["transport"] ?? "unknown",
                    ConnectedAt = DateTime.Now,
                    LastHeartbeat = DateTime.Now,
                    ClientName = Context.QueryString["clientName"] ?? Context.ConnectionId.Substring(0, 8),
                    HeartbeatsMissed = 0
                };
                _clients.TryAdd(Context.ConnectionId, clientInfo);
                NotifyUI($"[~] Client reconnected (re-tracked): {clientInfo.ClientName}");
            }

            UpdateUIClientList();

            base.Clients.Caller.onReconnected(new
            {
                connectionId = Context.ConnectionId,
                serverTime = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"),
                message = "Reconnected successfully"
            });

            return base.OnReconnected();
        }

        #endregion

        #region Client-callable Hub Methods

        /// <summary>
        /// Client sends a heartbeat to confirm it's alive
        /// </summary>
        public void Heartbeat(long clientTimestamp)
        {
            ClientInfo client;
            if (_clients.TryGetValue(Context.ConnectionId, out client))
            {
                client.LastHeartbeat = DateTime.Now;
                client.HeartbeatsMissed = 0;
            }

            // Respond with server timestamp for latency calculation
            base.Clients.Caller.onHeartbeatResponse(new
            {
                serverTimestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                clientTimestamp = clientTimestamp
            });
        }

        /// <summary>
        /// Ping/Pong for manual latency testing
        /// </summary>
        public void Ping(long sentAt)
        {
            base.Clients.Caller.onPong(new
            {
                sentAt = sentAt,
                serverTime = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
            });
        }

        /// <summary>
        /// Client registers with a display name
        /// </summary>
        public void Register(string clientName)
        {
            ClientInfo client;
            if (_clients.TryGetValue(Context.ConnectionId, out client))
            {
                var oldName = client.ClientName;
                client.ClientName = clientName;
                NotifyUI($"[i] Client renamed: {oldName} -> {clientName}");
                UpdateUIClientList();
            }

            base.Clients.Caller.onRegistered(new { clientName = clientName });
        }

        /// <summary>
        /// Broadcast a message to all connected clients
        /// </summary>
        public void SendMessage(string message)
        {
            ClientInfo sender;
            var senderName = "Unknown";
            if (_clients.TryGetValue(Context.ConnectionId, out sender))
                senderName = sender.ClientName;

            NotifyUI($"[MSG] {senderName}: {message}");

            base.Clients.All.onMessage(new
            {
                from = senderName,
                connectionId = Context.ConnectionId,
                message = message,
                timestamp = DateTime.Now.ToString("HH:mm:ss.fff")
            });
        }

        /// <summary>
        /// Get list of all connected clients
        /// </summary>
        public void GetConnectedClients()
        {
            var clientList = _clients.Values.Select(c => new
            {
                connectionId = c.ConnectionId,
                clientName = c.ClientName,
                transport = c.Transport,
                connectedAt = c.ConnectedAt.ToString("HH:mm:ss"),
                lastHeartbeat = c.LastHeartbeat.ToString("HH:mm:ss")
            }).ToArray();

            base.Clients.Caller.onClientList(clientList);
        }

        /// <summary>
        /// Get server status info
        /// </summary>
        public void GetServerStatus()
        {
            base.Clients.Caller.onServerStatus(new
            {
                serverTime = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"),
                uptime = (DateTime.Now - System.Diagnostics.Process.GetCurrentProcess().StartTime).ToString(@"dd\.hh\:mm\:ss"),
                totalClients = _clients.Count,
                heartbeatInterval = HEARTBEAT_INTERVAL_MS
            });
        }

        #endregion

        #region Server-side Heartbeat Monitor

        private static void StartHeartbeatTimer()
        {
            lock (_timerLock)
            {
                if (_heartbeatTimer != null) return;

                _heartbeatTimer = new Timer(HEARTBEAT_INTERVAL_MS);
                _heartbeatTimer.Elapsed += OnHeartbeatCheck;
                _heartbeatTimer.AutoReset = true;
                _heartbeatTimer.Start();
            }
        }

        private static void OnHeartbeatCheck(object sender, ElapsedEventArgs e)
        {
            var hub = GlobalHost.ConnectionManager.GetHubContext<StatusHub>();
            var now = DateTime.Now;

            foreach (var kvp in _clients)
            {
                var client = kvp.Value;
                var elapsed = now - client.LastHeartbeat;

                if (elapsed.TotalMilliseconds > HEARTBEAT_INTERVAL_MS * 1.5)
                {
                    client.HeartbeatsMissed++;

                    if (client.HeartbeatsMissed >= MAX_MISSED_HEARTBEATS)
                    {
                        NotifyUIStatic($"[!] Client {client.ClientName} missed {client.HeartbeatsMissed} heartbeats - possibly dead");
                    }
                }
            }

            // Send heartbeat ping to all clients
            hub.Clients.All.onServerHeartbeat(new
            {
                serverTimestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                connectedClients = _clients.Count
            });
        }

        #endregion

        #region UI Helpers

        public static int GetClientCount()
        {
            return _clients.Count;
        }

        public static ClientInfo[] GetAllClients()
        {
            return _clients.Values.ToArray();
        }

        private void UpdateUIClientList()
        {
            var app = System.Windows.Application.Current;
            if (app == null) return;

            app.Dispatcher.BeginInvoke(new Action(() =>
            {
                var mainWindow = app.MainWindow as MainWindow;
                mainWindow?.UpdateClientCount(_clients.Count);
                mainWindow?.UpdateClientList(_clients.Values.ToArray());
            }));
        }

        private void NotifyUI(string message)
        {
            NotifyUIStatic(message);
        }

        private static void NotifyUIStatic(string message)
        {
            var app = System.Windows.Application.Current;
            if (app == null) return;

            app.Dispatcher.BeginInvoke(new Action(() =>
            {
                var mainWindow = app.MainWindow as MainWindow;
                mainWindow?.Log(message);
            }));
        }

        #endregion
    }
}
