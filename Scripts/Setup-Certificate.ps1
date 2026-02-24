#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates a self-signed certificate for NMS SignalR Server and binds it to:
    1. Port 20201 (Self-hosted SignalR HTTPS + WSS)
    2. IIS Default HTTPS port 443

.DESCRIPTION
    This script performs the following:
    - Creates a self-signed certificate with IP SAN for 192.168.1.59
    - Registers the certificate in the Local Machine Personal store
    - Copies the certificate to Trusted Root CA store (so browsers trust it)
    - Creates URL ACL reservation for https://+:20201/
    - Binds the SSL certificate to port 20201 (handles both HTTPS and WSS for SignalR)
    - Binds the SSL certificate to IIS port 443
    - Adds a firewall rule for port 20201

.NOTES
    Run this script as Administrator on the server machine (192.168.1.59)
    WSS (WebSocket Secure) uses the same TLS binding as HTTPS on port 20201,
    so no separate WSS configuration is needed.
#>

param(
    [string]$IPAddress = "192.168.1.59",
    [int]$SignalRPort = 20201,
    [int]$IISPort = 443,
    [string]$CertFriendlyName = "NMS SignalR Certificate",
    [int]$CertValidYears = 10,
    [string]$IISSiteName = "Default Web Site"
)

$ErrorActionPreference = "Stop"

# ============================================================
# Application ID for the self-hosted SignalR server
# This GUID identifies the application in SSL bindings
# ============================================================
$AppId = "{8A3D89E7-F12B-4C56-9DEF-1A2B3C4D5E6F}"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  NMS SignalR Certificate Setup Script" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# STEP 1: Remove existing certificate (if any)
# ============================================================
Write-Host "[Step 1/8] Checking for existing certificates..." -ForegroundColor Yellow

$existingCerts = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.FriendlyName -eq $CertFriendlyName }
if ($existingCerts) {
    Write-Host "  Found existing certificate(s). Removing..." -ForegroundColor DarkYellow
    foreach ($cert in $existingCerts) {
        # Remove from Personal store
        Remove-Item -Path "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force
        # Remove from Trusted Root if exists
        $rootCert = Get-ChildItem -Path "Cert:\LocalMachine\Root" | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if ($rootCert) {
            Remove-Item -Path "Cert:\LocalMachine\Root\$($cert.Thumbprint)" -Force
        }
        Write-Host "  Removed certificate: $($cert.Thumbprint)" -ForegroundColor DarkYellow
    }
}
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# STEP 2: Create the self-signed certificate
# ============================================================
Write-Host "[Step 2/8] Creating self-signed certificate..." -ForegroundColor Yellow
Write-Host "  Subject:      CN=$IPAddress" -ForegroundColor Gray
Write-Host "  SAN:          IP=$IPAddress, DNS=$IPAddress" -ForegroundColor Gray
Write-Host "  Valid until:  $((Get-Date).AddYears($CertValidYears).ToString('yyyy-MM-dd'))" -ForegroundColor Gray
Write-Host "  Store:        LocalMachine\My" -ForegroundColor Gray

$cert = New-SelfSignedCertificate `
    -Subject "CN=$IPAddress" `
    -FriendlyName $CertFriendlyName `
    -TextExtension @("2.5.29.17={text}IPAddress=$IPAddress&DNS=$IPAddress") `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -KeyUsageProperty Sign `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears($CertValidYears) `
    -Type SSLServerAuthentication

$thumbprint = $cert.Thumbprint
Write-Host "  Certificate created successfully!" -ForegroundColor Green
Write-Host "  Thumbprint:   $thumbprint" -ForegroundColor Cyan

# ============================================================
# STEP 3: Copy certificate to Trusted Root CA store
# ============================================================
Write-Host "[Step 3/8] Adding certificate to Trusted Root CA store..." -ForegroundColor Yellow

$tempCertPath = "$env:TEMP\nms-signalr-cert.cer"

# Export the certificate (public key only)
Export-Certificate -Cert "Cert:\LocalMachine\My\$thumbprint" -FilePath $tempCertPath -Force | Out-Null

# Import to Trusted Root Certification Authorities
Import-Certificate -FilePath $tempCertPath -CertStoreLocation "Cert:\LocalMachine\Root" -Confirm:$false | Out-Null

# Clean up temp file
Remove-Item -Path $tempCertPath -Force -ErrorAction SilentlyContinue

# Export certificate files for distribution to client machines
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cerFilePath = Join-Path $scriptDir "NMS-SignalR-Certificate.cer"
$pfxFilePath = Join-Path $scriptDir "NMS-SignalR-Certificate.pfx"

# Export public key (.cer) - for clients that just need to trust the server
Export-Certificate -Cert "Cert:\LocalMachine\My\$thumbprint" -FilePath $cerFilePath -Force | Out-Null
Write-Host "  Exported .cer (public key) -> $cerFilePath" -ForegroundColor Cyan

# Export with private key (.pfx) - for backup or moving to another server
$pfxPassword = Read-Host -Prompt "  Enter password for .pfx export (or press Enter to skip)" -AsSecureString
if ($pfxPassword.Length -gt 0) {
    Export-PfxCertificate -Cert "Cert:\LocalMachine\My\$thumbprint" -FilePath $pfxFilePath -Password $pfxPassword -Force | Out-Null
    Write-Host "  Exported .pfx (with private key) -> $pfxFilePath" -ForegroundColor Cyan
}
else {
    Write-Host "  Skipped .pfx export (no password provided)." -ForegroundColor DarkYellow
}

Write-Host "  Certificate added to Trusted Root CA store." -ForegroundColor Green
Write-Host "  NOTE: Client machines also need this certificate in their Trusted Root store." -ForegroundColor DarkYellow

# ============================================================
# STEP 4: Remove existing SSL bindings (if any)
# ============================================================
Write-Host "[Step 4/8] Cleaning existing SSL bindings..." -ForegroundColor Yellow

# Remove existing SSL binding for SignalR port
$existingBinding = netsh http show sslcert ipport=0.0.0.0:$SignalRPort 2>&1
if ($existingBinding -notmatch "The system cannot find" -and $existingBinding -notmatch "does not exist") {
    Write-Host "  Removing existing SSL binding on port $SignalRPort..." -ForegroundColor DarkYellow
    netsh http delete sslcert ipport=0.0.0.0:$SignalRPort | Out-Null
}

# Remove existing SSL binding for IIS HTTPS port
$existingIISBinding = netsh http show sslcert ipport=0.0.0.0:$IISPort 2>&1
if ($existingIISBinding -notmatch "The system cannot find" -and $existingIISBinding -notmatch "does not exist") {
    Write-Host "  Removing existing SSL binding on port $IISPort..." -ForegroundColor DarkYellow
    netsh http delete sslcert ipport=0.0.0.0:$IISPort | Out-Null
}

Write-Host "  Done." -ForegroundColor Green

# ============================================================
# STEP 5: Create URL ACL reservation for self-hosted SignalR
# ============================================================
Write-Host "[Step 5/8] Creating URL ACL reservation for https://+:$SignalRPort/..." -ForegroundColor Yellow

# Remove existing URL ACL if it exists
$existingUrlAcl = netsh http show urlacl url=https://+:$SignalRPort/ 2>&1
if ($existingUrlAcl -notmatch "does not exist" -and $existingUrlAcl -notmatch "The system cannot find") {
    Write-Host "  Removing existing URL ACL..." -ForegroundColor DarkYellow
    netsh http delete urlacl url=https://+:$SignalRPort/ | Out-Null
}

# Add URL ACL - allows the current user and Everyone to listen
netsh http add urlacl url=https://+:$SignalRPort/ user=Everyone | Out-Null
Write-Host "  URL ACL reservation created." -ForegroundColor Green

# ============================================================
# STEP 6: Bind SSL certificate to port 20201 (SignalR HTTPS + WSS)
# ============================================================
Write-Host "[Step 6/8] Binding SSL certificate to port $SignalRPort (HTTPS + WSS)..." -ForegroundColor Yellow
Write-Host "  This binding handles both HTTPS and WSS (WebSocket Secure)." -ForegroundColor Gray
Write-Host "  SignalR negotiation uses HTTPS, then upgrades to WSS for WebSocket transport." -ForegroundColor Gray

$result = netsh http add sslcert ipport=0.0.0.0:$SignalRPort certhash=$thumbprint appid=$AppId certstorename=MY 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: Failed to bind SSL cert to port $SignalRPort" -ForegroundColor Red
    Write-Host "  Error: $result" -ForegroundColor Red
    Write-Host "  Trying alternative method..." -ForegroundColor Yellow

    # Alternative: bind to specific IP
    netsh http add sslcert ipport=${IPAddress}:$SignalRPort certhash=$thumbprint appid=$AppId certstorename=MY
}

Write-Host "  SSL certificate bound to port $SignalRPort." -ForegroundColor Green

# ============================================================
# STEP 7: Bind SSL certificate to IIS HTTPS port (443)
# ============================================================
Write-Host "[Step 7/8] Binding SSL certificate to IIS port $IISPort..." -ForegroundColor Yellow

# Try using IIS PowerShell module first
$iisModuleAvailable = Get-Module -ListAvailable -Name WebAdministration

if ($iisModuleAvailable) {
    Import-Module WebAdministration

    # Check if HTTPS binding already exists
    $existingHttpsBinding = Get-WebBinding -Name $IISSiteName -Protocol "https" -Port $IISPort -ErrorAction SilentlyContinue

    if (-not $existingHttpsBinding) {
        Write-Host "  Creating HTTPS binding for '$IISSiteName' on port $IISPort..." -ForegroundColor Gray
        New-WebBinding -Name $IISSiteName -Protocol "https" -Port $IISPort -IPAddress "*"
    }
    else {
        Write-Host "  HTTPS binding already exists for '$IISSiteName'." -ForegroundColor Gray
    }

    # Bind the certificate to the IIS HTTPS binding
    $binding = Get-WebBinding -Name $IISSiteName -Protocol "https" -Port $IISPort
    $binding.AddSslCertificate($thumbprint, "My")

    Write-Host "  SSL certificate bound to IIS '$IISSiteName' on port $IISPort." -ForegroundColor Green
}
else {
    Write-Host "  WebAdministration module not found. Using netsh fallback..." -ForegroundColor DarkYellow

    # Fallback: use netsh to bind SSL to port 443
    # IIS AppId (default): {4dc3e181-e14b-4a21-b022-59fc669b0914}
    $IISAppId = "{4dc3e181-e14b-4a21-b022-59fc669b0914}"
    netsh http add sslcert ipport=0.0.0.0:$IISPort certhash=$thumbprint appid=$IISAppId certstorename=MY

    Write-Host "  SSL certificate bound to port $IISPort via netsh." -ForegroundColor Green
    Write-Host "  NOTE: You may need to manually add HTTPS binding in IIS Manager." -ForegroundColor DarkYellow
}

# ============================================================
# STEP 8: Add firewall rule for SignalR port
# ============================================================
Write-Host "[Step 8/8] Configuring firewall rule for port $SignalRPort..." -ForegroundColor Yellow

# Remove existing rule if present
$existingRule = Get-NetFirewallRule -DisplayName "NMS SignalR Server (Port $SignalRPort)" -ErrorAction SilentlyContinue
if ($existingRule) {
    Remove-NetFirewallRule -DisplayName "NMS SignalR Server (Port $SignalRPort)"
    Write-Host "  Removed existing firewall rule." -ForegroundColor DarkYellow
}

New-NetFirewallRule `
    -DisplayName "NMS SignalR Server (Port $SignalRPort)" `
    -Description "Allow inbound TCP traffic for NMS SignalR Server (HTTPS + WSS)" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort $SignalRPort `
    -Action Allow `
    -Profile Domain, Private `
    | Out-Null

Write-Host "  Firewall rule created for port $SignalRPort." -ForegroundColor Green

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Certificate Thumbprint: $thumbprint" -ForegroundColor White
Write-Host "  Certificate Store:      LocalMachine\My" -ForegroundColor White
Write-Host ""
Write-Host "  SSL Bindings:" -ForegroundColor White
Write-Host "    Port $SignalRPort  -> SignalR self-host (HTTPS + WSS)" -ForegroundColor White
Write-Host "    Port $IISPort     -> IIS '$IISSiteName' (HTTPS)" -ForegroundColor White
Write-Host ""
Write-Host "  URLs:" -ForegroundColor White
Write-Host "    SignalR Server:  https://${IPAddress}:${SignalRPort}/signalr" -ForegroundColor White
Write-Host "    Angular Client:  https://${IPAddress}/NMSClient" -ForegroundColor White
Write-Host ""
Write-Host "  SignalR Transport Chain:" -ForegroundColor White
Write-Host "    1. Client connects via HTTPS to /signalr/negotiate" -ForegroundColor Gray
Write-Host "    2. If WebSockets available, upgrades to WSS (wss://${IPAddress}:${SignalRPort}/signalr/connect)" -ForegroundColor Gray
Write-Host "    3. Fallback: Server-Sent Events -> Long Polling (all over HTTPS)" -ForegroundColor Gray
Write-Host ""
Write-Host "  IMPORTANT - For client machines:" -ForegroundColor Yellow
Write-Host "    Install the .cer file in the client's Trusted Root" -ForegroundColor Yellow
Write-Host "    Certification Authorities store, or the browser will" -ForegroundColor Yellow
Write-Host "    show security warnings." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Exported certificate files (in Scripts/ folder):" -ForegroundColor White
Write-Host "    .cer file: $cerFilePath" -ForegroundColor Gray
Write-Host "      -> Give this to clients. Install via:" -ForegroundColor Gray
Write-Host "         certutil -addstore Root `"$cerFilePath`"" -ForegroundColor Gray
if (Test-Path $pfxFilePath) {
    Write-Host "    .pfx file: $pfxFilePath" -ForegroundColor Gray
    Write-Host "      -> Contains private key. Use to move cert to another server." -ForegroundColor Gray
}
Write-Host ""

# ============================================================
# VERIFICATION
# ============================================================
Write-Host "Verifying SSL bindings..." -ForegroundColor Yellow
Write-Host ""
Write-Host "--- Port $SignalRPort SSL Binding ---" -ForegroundColor Cyan
netsh http show sslcert ipport=0.0.0.0:$SignalRPort
Write-Host ""
Write-Host "--- Port $IISPort SSL Binding ---" -ForegroundColor Cyan
netsh http show sslcert ipport=0.0.0.0:$IISPort
Write-Host ""
Write-Host "--- URL ACL ---" -ForegroundColor Cyan
netsh http show urlacl url=https://+:$SignalRPort/
