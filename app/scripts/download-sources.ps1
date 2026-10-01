$ErrorActionPreference = "Stop"
$out = "D:\uniterm\kaihongos\thirdparty\downloads"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$files = @(
  @{ name = "openssl-3.5.4.tar.gz"; urls = @(
    "https://gitee.com/mirrors/openssl/raw/master/NOTICE.md",
    "https://mirrors.huaweicloud.com/openssl/openssl-3.5.4.tar.gz",
    "https://github.com/openssl/openssl/releases/download/OpenSSL_3_5_4/openssl-3.5.4.tar.gz"
  )},
  @{ name = "libssh-0.11.1.tar.xz"; urls = @(
    "https://www.libssh.org/files/0.11/libssh-0.11.1.tar.xz",
    "https://mirrors.huaweicloud.com/libssh/libssh-0.11.1.tar.xz",
    "https://ftp.libssh.org/libssh-0.11.1.tar.xz"
  )}
)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
foreach ($f in $files) {
  $dest = Join-Path $out $f.name
  if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 100KB)) { Write-Host "SKIP $($f.name)"; continue }
  $ok = $false
  foreach ($u in $f.urls) {
    try {
      Write-Host "TRY $u"
      Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -TimeoutSec 120
      if ((Get-Item $dest).Length -gt 100KB) { Write-Host "OK  $($f.name) $((Get-Item $dest).Length) bytes via $u"; $ok = $true; break }
    } catch { Write-Host "FAIL $u : $($_.Exception.Message)" }
  }
  if (-not $ok) { Write-Host "ALL-MIRRORS-FAILED $($f.name)" }
}
Get-ChildItem $out | ForEach-Object { Write-Host ("{0}  {1}" -f $_.Name, $_.Length) }
