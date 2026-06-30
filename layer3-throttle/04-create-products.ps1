#Requires -Version 7.0
<#
  Camada 3 - Passo 4: cria um Product por time com a policy llm-token-limit (TPM=429, quota=403)
  e uma subscription (chave) por time. Os limites vem do teams.json.

  llm-token-limit corta o consumo de token em tempo real:
    - estouro de tokens-per-minute -> HTTP 429 + Retry-After
    - estouro de token-quota        -> HTTP 403

  Exemplo:
    ./04-create-products.ps1 -SubscriptionId <SUB> -ResourceGroup rg-foundry-gw-01 `
       -ApimName apim-foundry-gw-01 -TeamsFile ./teams.json
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$ApimName,
  [string]$ApiPath = '',
  [string]$TeamsFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$st = Get-GatewayState
if (-not $st.apimId) { throw "Rode 01-deploy-apim.ps1 antes (estado nao encontrado)." }
if (-not $ApiPath)   { $ApiPath = if ($st.apiPath) { $st.apiPath } else { 'foundry' } }
if (-not $TeamsFile) { $TeamsFile = Join-Path $PSScriptRoot 'teams.json' }
if (-not (Test-Path $TeamsFile)) {
  throw "teams.json nao encontrado. Copie teams.example.json para teams.json e ajuste os limites por time."
}
$apimId = $st.apimId
$apiVer = if ($st.apiVersion) { $st.apiVersion } else { '2023-05-01-preview' }
$teams  = Get-Content -Raw $TeamsFile | ConvertFrom-Json
$tmpl   = Get-Content -Raw (Join-Path $PSScriptRoot 'policies/product-policy.template.xml')

az account set --subscription $SubscriptionId | Out-Null

$results = @()
foreach ($team in $teams) {
  $prodId = $team.product
  Write-Host "== Product $prodId ==" -ForegroundColor Cyan
  if (-not (az apim product show -g $ResourceGroup --service-name $ApimName --product-id $prodId --query id -o tsv 2>$null)) {
    az apim product create -g $ResourceGroup --service-name $ApimName --product-id $prodId `
      --product-name $team.displayName --subscription-required true `
      --approval-required false --state published -o none
  }
  az apim product api add -g $ResourceGroup --service-name $ApimName --product-id $prodId --api-id $ApiPath -o none 2>$null

  Write-Host "   policy llm-token-limit (TPM=$($team.tokensPerMinute), quota=$($team.tokenQuota)/$($team.tokenQuotaPeriod))" -ForegroundColor Yellow
  $xml = $tmpl.Replace("{{TPM}}", "$($team.tokensPerMinute)").Replace("{{QUOTA}}", "$($team.tokenQuota)").Replace("{{PERIOD}}", $team.tokenQuotaPeriod)
  Invoke-ArmPut "https://management.azure.com$apimId/products/$prodId/policies/policy?api-version=$apiVer" `
    @{ properties = @{ format = 'rawxml'; value = $xml } }

  $sid = "$prodId-sub"
  Write-Host "   subscription $sid" -ForegroundColor Yellow
  Invoke-ArmPut "https://management.azure.com$apimId/subscriptions/$($sid)?api-version=$apiVer" `
    @{ properties = @{ scope = "$apimId/products/$prodId"; displayName = "$($team.displayName) sub"; state = "active" } }
  $key = az rest --method post --uri "https://management.azure.com$apimId/subscriptions/$sid/listSecrets?api-version=$apiVer" `
    --headers "Accept=application/json" --query primaryKey -o tsv

  $results += [pscustomobject]@{ product = $prodId; subscriptionKey = $key; tpm = $team.tokensPerMinute; quota = $team.tokenQuota }
}

# Chaves NAO vao para o git (.state.json e ignorado). Guarde-as no seu cofre (Key Vault).
Save-GatewayState @{ products = $results }
Write-Host "`nOK. Chaves geradas (guarde no Key Vault). Conexao do Playground: 05-connect-playground.ps1" -ForegroundColor Green
$results | Format-Table -AutoSize
