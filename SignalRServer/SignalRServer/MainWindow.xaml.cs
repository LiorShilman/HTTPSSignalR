using System;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media;
using Microsoft.Owin.Hosting;

namespace SignalRServer
{
    public partial class MainWindow : Window
    {
        private IDisposable _server;
        private bool _isRunning;
        private const string ServerUrl = "https://+:20201";

        private readonly ObservableCollection<ClientInfo> _clientList = new ObservableCollection<ClientInfo>();

        public MainWindow()
        {
            InitializeComponent();
            ClientListBox.ItemsSource = _clientList;
            Log("NMS SignalR Server initialized.");
            Log($"Target URL: {ServerUrl}");
            Log("Press 'Start Server' to begin listening.");
        }

        private void BtnStartStop_Click(object sender, RoutedEventArgs e)
        {
            if (_isRunning)
                StopServer();
            else
                StartServer();
        }

        private void BtnClearLog_Click(object sender, RoutedEventArgs e)
        {
            LogBox.Clear();
        }

        private void StartServer()
        {
            try
            {
                Log("Starting server...");
                _server = WebApp.Start<Startup>(ServerUrl);
                _isRunning = true;

                StatusIndicator.Fill = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#2ECC71"));
                StatusText.Text = "Server Running";
                BtnStartStop.Content = "Stop Server";
                BtnStartStop.Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#E74C3C"));

                Log($"Server started at {ServerUrl}");
                Log("SignalR endpoint: https://192.168.1.59:20201/signalr");
                Log("WSS endpoint:    wss://192.168.1.59:20201/signalr/connect");
                Log("---");
                Log("KeepAlive: 5s | DisconnectTimeout: 15s | Heartbeat: 10s");
                Log("Waiting for client connections...");
            }
            catch (Exception ex)
            {
                Log($"ERROR: {ex.Message}");
                if (ex.InnerException != null)
                    Log($"  Inner: {ex.InnerException.Message}");

                MessageBox.Show(
                    $"Failed to start server.\n\n{ex.Message}\n\nMake sure:\n" +
                    "1. Certificate script has been run\n" +
                    "2. URL ACL is registered\n" +
                    "3. Port 20201 is not in use\n" +
                    "4. Running as Administrator",
                    "Server Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void StopServer()
        {
            try
            {
                _server?.Dispose();
                _server = null;
                _isRunning = false;

                StatusIndicator.Fill = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#E74C3C"));
                StatusText.Text = "Server Stopped";
                BtnStartStop.Content = "Start Server";
                BtnStartStop.Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#2ECC71"));

                _clientList.Clear();
                Log("Server stopped.");
            }
            catch (Exception ex)
            {
                Log($"ERROR: {ex.Message}");
            }
        }

        public void Log(string message)
        {
            Dispatcher.Invoke(() =>
            {
                LogBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}");
                LogBox.ScrollToEnd();
            });
        }

        public void UpdateClientCount(int count)
        {
            Dispatcher.Invoke(() =>
            {
                ClientCount.Text = $"Connected Clients: {count}";
            });
        }

        public void UpdateClientList(ClientInfo[] clients)
        {
            Dispatcher.Invoke(() =>
            {
                _clientList.Clear();
                foreach (var client in clients)
                    _clientList.Add(client);
            });
        }

        protected override void OnClosed(EventArgs e)
        {
            if (_isRunning)
            {
                _server?.Dispose();
            }
            base.OnClosed(e);
        }
    }
}
