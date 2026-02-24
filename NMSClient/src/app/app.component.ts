import { Component, OnInit, OnDestroy, ViewChild, ElementRef, AfterViewChecked } from '@angular/core';
import { SignalRService, ConnectionState, ConnectionStats } from './services/signalr.service';
import { Subscription } from 'rxjs';

@Component({
  selector: 'app-root',
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.css']
})
export class AppComponent implements OnInit, OnDestroy, AfterViewChecked {
  @ViewChild('logPanel') logPanel!: ElementRef;

  connectionState: ConnectionState = 'Disconnected';
  stats: ConnectionStats = {
    transport: '-',
    connectionId: '-',
    connectedAt: null,
    lastHeartbeat: null,
    latencyMs: 0,
    reconnectCount: 0,
    heartbeatCount: 0
  };
  messages: string[] = [];
  messageInput = '';
  clientName = 'Angular-Client';

  private subs: Subscription[] = [];
  private shouldScroll = false;

  constructor(private signalRService: SignalRService) {}

  ngOnInit(): void {
    this.subs.push(
      this.signalRService.connectionState$.subscribe(state => {
        this.connectionState = state;
      }),
      this.signalRService.messages$.subscribe(msgs => {
        this.messages = msgs;
        this.shouldScroll = true;
      }),
      this.signalRService.stats$.subscribe(stats => {
        this.stats = stats;
      })
    );

    this.connect();
  }

  ngAfterViewChecked(): void {
    if (this.shouldScroll && this.logPanel) {
      const el = this.logPanel.nativeElement;
      el.scrollTop = el.scrollHeight;
      this.shouldScroll = false;
    }
  }

  connect(): void {
    this.signalRService.start(this.clientName);
  }

  disconnect(): void {
    this.signalRService.stop();
  }

  ping(): void {
    this.signalRService.ping();
  }

  sendMessage(): void {
    if (this.messageInput.trim()) {
      this.signalRService.sendMessage(this.messageInput.trim());
      this.messageInput = '';
    }
  }

  getClients(): void {
    this.signalRService.getConnectedClients();
  }

  getServerStatus(): void {
    this.signalRService.getServerStatus();
  }

  getStateClass(): string {
    switch (this.connectionState) {
      case 'Connected': return 'state-connected';
      case 'Connecting': return 'state-connecting';
      case 'Reconnecting': return 'state-reconnecting';
      default: return 'state-disconnected';
    }
  }

  trackByIndex(index: number): number {
    return index;
  }

  formatTime(date: Date | null): string {
    if (!date) return '-';
    return date.toLocaleTimeString('en-US', { hour12: false });
  }

  ngOnDestroy(): void {
    this.subs.forEach(s => s.unsubscribe());
    this.signalRService.stop();
  }
}
