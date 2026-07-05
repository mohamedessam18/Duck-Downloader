param(
  [string]$TunnelName = "duck-downloader-api",
  [string]$Hostname = "api.duckdownloader.site",
  [string]$Origin = "http://127.0.0.1:8000",
  [switch]$SkipServiceInstall
)

$ErrorActionPreference = "Stop"

$cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cloudflared) {
  throw "cloudflared is not installed or is not on PATH."
}

$cloudflaredDir = Join-Path $env:USERPROFILE ".cloudflared"
$certPath = Join-Path $cloudflaredDir "cert.pem"
if (-not (Test-Path $certPath)) {
  throw "Cloudflare origin certificate not found at $certPath. Run: cloudflared tunnel login"
}

New-Item -ItemType Directory -Force -Path $cloudflaredDir | Out-Null

$tunnelsJson = cloudflared tunnel list --name $TunnelName --output json
$tunnels = @()
if ($tunnelsJson -and $tunnelsJson -ne "null") {
  $tunnels = @($tunnelsJson | ConvertFrom-Json)
}

if ($tunnels.Count -eq 0 -or $tunnels[0] -eq $null) {
  cloudflared tunnel create $TunnelName
  $tunnelsJson = cloudflared tunnel list --name $TunnelName --output json
  if ($tunnelsJson -and $tunnelsJson -ne "null") {
    $tunnels = @($tunnelsJson | ConvertFrom-Json)
  } else {
    $tunnels = @()
  }
}

if ($tunnels.Count -eq 0 -or $tunnels[0] -eq $null) {
  throw "Tunnel $TunnelName was not found after create."
}

$tunnelId = $tunnels[0].id
$credentialsPath = Join-Path $cloudflaredDir "$tunnelId.json"
if (-not (Test-Path $credentialsPath)) {
  throw "Tunnel credentials file not found at $credentialsPath."
}

$configPath = Join-Path $cloudflaredDir "config.yml"
$config = @"
tunnel: $TunnelName
credentials-file: $credentialsPath

ingress:
  - hostname: $Hostname
    service: $Origin
  - service: http_status:404
"@
$config | Set-Content -Encoding ASCII $configPath

cloudflared tunnel route dns $TunnelName $Hostname

if (-not $SkipServiceInstall) {
  cloudflared service install
}

Write-Host "Cloudflare tunnel is configured."
Write-Host "Tunnel: $TunnelName ($tunnelId)"
Write-Host "Hostname: https://$Hostname"
Write-Host "Config: $configPath"
