import { Injectable, NgZone } from '@angular/core';
import { BehaviorSubject, Subject } from 'rxjs';

declare var $: any;

export type ConnectionState = 'Disconnected' | 'Connecting' | 'Connected' | 'Reconnecting';

export interface ConnectionStats {
  transport: string;
  connectionId: string;
  connectedAt: Date | null;
  lastHeartbeat: Date | null;
  latencyMs: number;
  reconnectCount: number;
  heartbeatCount: number;
}

@Injectable({ providedIn: 'root' })
export class SignalRService {
  private connection: any = null;
  private hubProxy: any = null;

  // Auto-reconnect configuration
  private autoReconnect = true;
  private reconnectAttempt = 0;
  private readonly MAX_RECONNECT_DELAY_MS = 30000;
  private readonly INITIAL_RECONNECT_DELAY_MS = 1000;
  private reconnectTimer: any = null;

  // Client-side heartbeat
  private heartbeatTimer: any = null;
  private readonly HEARTBEAT_INTERVAL_MS = 10000;

  // Observables
  readonly connectionState$ = new BehaviorSubject<ConnectionState>('Disconnected');
  readonly messages$ = new BehaviorSubject<string[]>([]);
  readonly stats$ = new BehaviorSubject<ConnectionStats>({
    transport: '-',
    connectionId: '-',
    connectedAt: null,
    lastHeartbeat: null,
    latencyMs: 0,
    reconnectCount: 0,
    heartbeatCount: 0
  });

  // Events from server
  readonly serverMessage$ = new Subject<{ from: string; message: string; timestamp: string }>();
  readonly clientListChanged$ = new Subject<any[]>();

  private readonly SERVER_URL = 'https://192.168.1.59:20201';
  private readonly HUB_NAME = 'statusHub';

  constructor(private zone: NgZone) {}

  // ==========================================
  //  CONNECTION MANAGEMENT
  // ==========================================

  start(clientName?: string): void {
    // Clean up any existing connection
    this.cleanup();

    this.autoReconnect = true;
    this.addMessage('Initializing SignalR connection...');
    this.addMessage(`Server: ${this.SERVER_URL}/signalr`);

    // Create connection
    this.connection = $.hubConnection(this.SERVER_URL);

    // Pass client name as query string
    if (clientName) {
      this.connection.qs = { clientName: clientName };
    }

    // Create hub proxy BEFORE registering events
    this.hubProxy = this.connection.createHubProxy(this.HUB_NAME);

    // Register all client methods
    this.registerClientMethods();

    // Register connection events
    this.registerConnectionEvents();

    // Connect
    this.setState('Connecting');
    this.addMessage('Connecting... (transports: webSockets, longPolling)');

    this.connection.start({
      transport: ['webSockets', 'longPolling'],
      waitForPageLoad: false
    })
    .done(() => {
      this.zone.run(() => {
        this.onConnectionEstablished();
      });
    })
    .fail((err: any) => {
      this.zone.run(() => {
        this.setState('Disconnected');
        this.addMessage(`Connection FAILED: ${err}`);
        this.scheduleReconnect();
      });
    });
  }

  stop(): void {
    this.autoReconnect = false;
    this.cleanup();
    this.addMessage('Connection stopped by user.');
    this.setState('Disconnected');
  }

  private cleanup(): void {
    this.stopHeartbeat();
    this.clearReconnectTimer();

    if (this.connection) {
      try {
        this.connection.stop();
      } catch (e) { }
      this.connection = null;
      this.hubProxy = null;
    }
  }

  // ==========================================
  //  AUTO RECONNECT (Exponential Backoff)
  // ==========================================

  private scheduleReconnect(): void {
    if (!this.autoReconnect) return;

    this.clearReconnectTimer();

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (max)
    const delay = Math.min(
      this.INITIAL_RECONNECT_DELAY_MS * Math.pow(2, this.reconnectAttempt),
      this.MAX_RECONNECT_DELAY_MS
    );

    this.reconnectAttempt++;
    this.addMessage(`Auto-reconnect attempt #${this.reconnectAttempt} in ${(delay / 1000).toFixed(1)}s...`);

    this.reconnectTimer = setTimeout(() => {
      if (this.autoReconnect) {
        this.addMessage(`Reconnecting (attempt #${this.reconnectAttempt})...`);
        this.start();
      }
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  // ==========================================
  //  HEARTBEAT (Client-side)
  // ==========================================

  private startHeartbeat(): void {
    this.stopHeartbeat();

    this.heartbeatTimer = setInterval(() => {
      if (this.connectionState$.value === 'Connected' && this.hubProxy) {
        const timestamp = Date.now();
        this.hubProxy.invoke('heartbeat', timestamp)
          .fail((err: any) => {
            this.zone.run(() => {
              this.addMessage(`Heartbeat failed: ${err}`);
            });
          });

        this.updateStats({ heartbeatCount: this.stats$.value.heartbeatCount + 1 });
      }
    }, this.HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  // ==========================================
  //  HUB METHODS (Client -> Server)
  // ==========================================

  ping(): void {
    if (!this.isConnected()) return;

    const sentAt = Date.now();
    this.hubProxy.invoke('ping', sentAt)
      .fail((err: any) => {
        this.zone.run(() => this.addMessage(`Ping failed: ${err}`));
      });
    this.addMessage(`Ping sent...`);
  }

  sendMessage(message: string): void {
    if (!this.isConnected()) return;
    this.hubProxy.invoke('sendMessage', message);
  }

  getConnectedClients(): void {
    if (!this.isConnected()) return;
    this.hubProxy.invoke('getConnectedClients');
  }

  getServerStatus(): void {
    if (!this.isConnected()) return;
    this.hubProxy.invoke('getServerStatus');
  }

  isConnected(): boolean {
    return this.connectionState$.value === 'Connected' && this.hubProxy != null;
  }

  // ==========================================
  //  CLIENT METHODS (Server -> Client)
  // ==========================================

  private registerClientMethods(): void {
    // Connection confirmed by server
    this.hubProxy.on('onConnected', (data: any) => {
      this.zone.run(() => {
        this.addMessage(`Server confirmed: ${data.message}`);
        this.addMessage(`Server time: ${data.serverTime}`);
      });
    });

    // Reconnection confirmed by server
    this.hubProxy.on('onReconnected', (data: any) => {
      this.zone.run(() => {
        this.addMessage(`Server confirmed reconnection: ${data.message}`);
      });
    });

    // Heartbeat response - calculate latency
    this.hubProxy.on('onHeartbeatResponse', (data: any) => {
      this.zone.run(() => {
        const latency = Date.now() - data.clientTimestamp;
        this.updateStats({
          latencyMs: latency,
          lastHeartbeat: new Date()
        });
      });
    });

    // Ping/Pong response
    this.hubProxy.on('onPong', (data: any) => {
      this.zone.run(() => {
        const latency = Date.now() - data.sentAt;
        this.addMessage(`Pong! Latency: ${latency}ms`);
        this.updateStats({ latencyMs: latency });
      });
    });

    // Server heartbeat (server -> all clients)
    this.hubProxy.on('onServerHeartbeat', (data: any) => {
      this.zone.run(() => {
        this.updateStats({ lastHeartbeat: new Date() });
      });
    });

    // Another client joined
    this.hubProxy.on('onClientJoined', (data: any) => {
      this.zone.run(() => {
        this.addMessage(`Client joined: ${data.clientName} (${data.transport}) | Total: ${data.totalClients}`);
      });
    });

    // Another client left
    this.hubProxy.on('onClientLeft', (data: any) => {
      this.zone.run(() => {
        this.addMessage(`Client left: ${data.clientName} | Total: ${data.totalClients}`);
      });
    });

    // Message from another client
    this.hubProxy.on('onMessage', (data: any) => {
      this.zone.run(() => {
        this.addMessage(`[${data.from}] ${data.message}`);
        this.serverMessage$.next(data);
      });
    });

    // Client list response
    this.hubProxy.on('onClientList', (clients: any[]) => {
      this.zone.run(() => {
        this.addMessage(`Connected clients: ${clients.length}`);
        clients.forEach(c => {
          this.addMessage(`  - ${c.clientName} (${c.transport}) since ${c.connectedAt}`);
        });
        this.clientListChanged$.next(clients);
      });
    });

    // Server status response
    this.hubProxy.on('onServerStatus', (status: any) => {
      this.zone.run(() => {
        this.addMessage(`Server uptime: ${status.uptime} | Clients: ${status.totalClients}`);
      });
    });

    // Registration confirmed
    this.hubProxy.on('onRegistered', (data: any) => {
      this.zone.run(() => {
        this.addMessage(`Registered as: ${data.clientName}`);
      });
    });
  }

  // ==========================================
  //  CONNECTION EVENTS
  // ==========================================

  private registerConnectionEvents(): void {
    const stateMap: { [key: number]: ConnectionState } = {
      0: 'Connecting',
      1: 'Connected',
      2: 'Reconnecting',
      4: 'Disconnected'
    };

    this.connection.stateChanged((change: any) => {
      this.zone.run(() => {
        const oldState = stateMap[change.oldState] || 'Unknown';
        const newState = stateMap[change.newState] || 'Disconnected';
        this.setState(newState);
        this.addMessage(`State: ${oldState} -> ${newState}`);
      });
    });

    this.connection.reconnecting(() => {
      this.zone.run(() => {
        this.addMessage('SignalR auto-reconnecting...');
        this.stopHeartbeat();
      });
    });

    this.connection.reconnected(() => {
      this.zone.run(() => {
        const stats = this.stats$.value;
        this.updateStats({ reconnectCount: stats.reconnectCount + 1 });
        this.addMessage(`Reconnected! (total reconnects: ${stats.reconnectCount + 1})`);
        this.reconnectAttempt = 0;
        this.startHeartbeat();
      });
    });

    this.connection.disconnected(() => {
      this.zone.run(() => {
        this.setState('Disconnected');
        this.stopHeartbeat();
        this.addMessage('Disconnected from server.');

        // Only auto-reconnect if not manually stopped
        if (this.autoReconnect) {
          this.scheduleReconnect();
        }
      });
    });

    this.connection.error((err: any) => {
      this.zone.run(() => {
        this.addMessage(`Connection error: ${err.message || err}`);
      });
    });
  }

  private onConnectionEstablished(): void {
    const transport = this.connection.transport?.name || 'unknown';
    this.setState('Connected');
    this.reconnectAttempt = 0;

    this.updateStats({
      transport: transport,
      connectionId: this.connection.id,
      connectedAt: new Date(),
      lastHeartbeat: new Date(),
      latencyMs: 0
    });

    this.addMessage(`Connected! Transport: ${transport}`);
    this.addMessage(`Connection ID: ${this.connection.id}`);

    if (transport === 'webSockets') {
      this.addMessage('Using WSS (WebSocket Secure)');
    }

    // Start client-side heartbeat
    this.startHeartbeat();
  }

  // ==========================================
  //  HELPERS
  // ==========================================

  private setState(state: ConnectionState): void {
    this.connectionState$.next(state);
  }

  private updateStats(partial: Partial<ConnectionStats>): void {
    this.stats$.next({ ...this.stats$.value, ...partial });
  }

  private addMessage(msg: string): void {
    const timestamp = new Date().toLocaleTimeString('en-US', { hour12: false });
    const current = this.messages$.value;
    const updated = [...current, `[${timestamp}] ${msg}`].slice(-300);
    this.messages$.next(updated);
  }
}
