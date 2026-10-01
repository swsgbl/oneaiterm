# internal: build unsgned debug profile json for net.uniterm.poc
# args: <appCert.cer> <out.json>
param(
  [Parameter(Mandatory=$true)][string]$AppCert,
  [Parameter(Mandatory=$true)][string]$OutJson
)
$ErrorActionPreference = 'Stop'

# take the FIRST certificate (leaf) from the certChain file
$raw = Get-Content -Raw $AppCert
$blocks = [regex]::Matches($raw, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----')
if ($blocks.Count -lt 1) { throw "no PEM block found in $AppCert" }
$leaf = $blocks[0].Value + "`n"

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$after = $now + 315360000  # +10 years

$uuid = [guid]::NewGuid().ToString()

$profile = [ordered]@{
  'version-name' = '2.0.0'
  'version-code' = 2
  'uuid' = $uuid
  'validity' = [ordered]@{ 'not-before' = $now; 'not-after' = $after }
  'type' = 'debug'
  'bundle-info' = [ordered]@{
    'developer-id' = 'uniterm'
    'development-certificate' = $leaf
    'bundle-name' = 'net.uniterm.poc'
    'apl' = 'normal'
    'app-feature' = 'hos_normal_app'
  }
  'acls' = [ordered]@{ 'allowed-acls' = @('') }
  'permissions' = [ordered]@{ 'restricted-permissions' = @('') }
  'debug-info' = [ordered]@{ 'device-ids' = @(); 'device-id-type' = 'udid' }
  'issuer' = 'uniterm Profile Sign CA'
}

$json = $profile | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($OutJson, $json, [System.Text.UTF8Encoding]::new($false))
Write-Output "profile written: $OutJson ($($json.Length) chars)"
