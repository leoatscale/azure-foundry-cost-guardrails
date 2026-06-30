#Requires -Version 7.0
<#
  Camada 3 - helpers compartilhados (sem nada fixo de ambiente).
  Guarda o estado entre os passos (apimId, principalId, gatewayUrl, foundryId...) num
  arquivo .state.json local (ignorado pelo git).
#>
$script:StateFile = Join-Path $PSScriptRoot '.state.json'

function Get-GatewayState {
  if (-not (Test-Path $script:StateFile)) { return @{} }
  return (Get-Content -Raw $script:StateFile | ConvertFrom-Json -AsHashtable)
}

function Save-GatewayState([hashtable] $Patch) {
  $s = Get-GatewayState
  if ($null -eq $s) { $s = @{} }
  foreach ($k in $Patch.Keys) { $s[$k] = $Patch[$k] }
  ($s | ConvertTo-Json -Depth 8) | Set-Content -Encoding utf8 $script:StateFile
}

# PUT ARM com body UTF-8 sem BOM e Accept=application/json (evita crash de display do az
# quando a resposta nao e JSON puro).
function Invoke-ArmPut([string] $Uri, $Obj) {
  $json = $Obj | ConvertTo-Json -Depth 8
  $f = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($false)))
  try {
    az rest --method put --uri $Uri --headers "Content-Type=application/json" "Accept=application/json" --body "@$f" -o none
    if ($LASTEXITCODE -ne 0) { throw "Falha no ARM PUT: $Uri" }
  } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
