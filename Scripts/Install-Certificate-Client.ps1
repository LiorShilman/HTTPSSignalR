#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the NMS SignalR server certificate on a client machine.

.DESCRIPTION
    Run this script on any client machine that needs to trust the NMS SignalR server.
    It imports the .cer file into the Trusted Root Certification Authorities store.

.NOTES
    1. Copy this script + NMS-SignalR-Certificate.cer to the client machine
    2. Run as Administrator
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cerFilePath = Join-Path $scriptDir "NMS-SignalR-Certificate.cer"

if (-not (Test-Path $cerFilePath)) {
    Write-Host "ERROR: Certificate file not found!" -ForegroundColor Red
    Write-Host "Expected: $cerFilePath" -ForegroundColor Red
    Write-Host ""
    Write-Host "Make sure 'NMS-SignalR-Certificate.cer' is in the same folder as this script." -ForegroundColor Yellow
    exit 1
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  NMS SignalR - Client Certificate Installation" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Show certificate details
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cerFilePath)
Write-Host "  Certificate: $($cert.Subject)" -ForegroundColor White
Write-Host "  Thumbprint:  $($cert.Thumbprint)" -ForegroundColor Gray
Write-Host "  Valid until:  $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
Write-Host ""

# Check if already installed
$existing = Get-ChildItem -Path "Cert:\LocalMachine\Root" | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
if ($existing) {
    Write-Host "  Certificate is already installed in Trusted Root store." -ForegroundColor Green
    Write-Host "  No action needed." -ForegroundColor Green
    exit 0
}

# Install
Write-Host "  Installing certificate to Trusted Root CA store..." -ForegroundColor Yellow
Import-Certificate -FilePath $cerFilePath -CertStoreLocation "Cert:\LocalMachine\Root" -Confirm:$false | Out-Null

# Verify
$installed = Get-ChildItem -Path "Cert:\LocalMachine\Root" | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
if ($installed) {
    Write-Host "  Certificate installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  The browser will now trust https://192.168.1.59:20201" -ForegroundColor White
    Write-Host "  and https://192.168.1.59 without security warnings." -ForegroundColor White
}
else {
    Write-Host "  ERROR: Installation failed!" -ForegroundColor Red
}
