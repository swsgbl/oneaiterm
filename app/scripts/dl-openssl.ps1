$ErrorActionPreference = "Continue"
$out = "D:\uniterm\kaihongos\thirdparty\downloads"
$dest = Join-Path $out "openssl-3.5.4.tar.gz"
Remove-Item $dest -ErrorAction SilentlyContinue
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$urls = @(
  "https://www.openssl.org/source/openssl-3.5.4.tar.gz",
  "https://github.com/openssl/openssl/releases/download/OpenSSL_3_5_4/openssl-3.5.4.tar.gz",
  "https://gitee.com/mirrors/openssl/repository/archive/3.5.4.zip"
)
foreach ($u in $urls) {
  try {
    Write-Host "TRY $u"
    Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -TimeoutSec 180
    $len = (Get-Item $dest).Length
    Write-Host "  got $len bytes"
    if ($len -gt 1000000) { Write-Host "OK $u"; break }
  } catch { Write-Host "FAIL $($_.Exception.Message)" }
}
