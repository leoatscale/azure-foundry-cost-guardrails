#Requires -Version 7.0
<#
  Camada 3 - Passo 3: aplica a policy de API (auth via Managed Identity + emit-token-metric).
  A telemetria de token vai para o Application Insights; o rate limit por time vem no Passo 4.

  Exemplo:
    ./03-apply-token-policy.ps1 -SubscriptionId <SUB> -ResourceGroup rg-foundry-gw-01 -ApimName apim-foundry-gw-01
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$ApimName,
  [string]$ApiPath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$st = Get-GatewayState
if (-not $st.apimId) { throw "Rode 01-deploy-apim.ps1 antes (estado nao encontrado)." }
if (-not $ApiPath) { $ApiPath = if ($st.apiPath) { $st.apiPath } else { 'foundry' } }
$apimId = $st.apimId
$apiVer = if ($st.apiVersion) { $st.apiVersion } else { '2023-05-01-preview' }
$xml = Get-Content -Raw (Join-Path $PSScriptRoot 'policies/api-policy.xml')

az account set --subscription $SubscriptionId | Out-Null

$uri = "https://management.azure.com$apimId/apis/$ApiPath/policies/policy?api-version=$apiVer"
Write-Host "PUT $uri" -ForegroundColor Cyan
Invoke-ArmPut $uri @{ properties = @{ format = 'rawxml'; value = $xml } }
Write-Host "OK. Policy da API '$ApiPath' aplicada. Prossiga: 04-create-products.ps1" -ForegroundColor Green
