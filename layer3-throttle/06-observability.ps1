#Requires -Version 7.0
<#
  Camada 3 - Passo 6: observabilidade.
  - Logger applicationInsights no APIM.
  - Diagnostic da API -> App Insights (loga todos os erros).
  - Alerta de pico de 4xx (429/403) no gateway.

  Exemplo:
    ./06-observability.ps1 -SubscriptionId <SUB> -ResourceGroup rg-foundry-gw-01 -ApimName apim-foundry-gw-01
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$ApimName,
  [string]$ApiPath = '',
  [string]$AppInsights = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$st = Get-GatewayState
if (-not $st.apimId) { throw "Rode 01-deploy-apim.ps1 antes (estado nao encontrado)." }
if (-not $ApiPath)     { $ApiPath     = if ($st.apiPath) { $st.apiPath } else { 'foundry' } }
if (-not $AppInsights) { $AppInsights = if ($st.appInsights) { $st.appInsights } else { "appi-$ApimName" } }
$apimId = $st.apimId
$apiVer = if ($st.apiVersion) { $st.apiVersion } else { '2023-05-01-preview' }

az account set --subscription $SubscriptionId | Out-Null

Write-Host "== App Insights keys ==" -ForegroundColor Cyan
$ai = az monitor app-insights component show --app $AppInsights -g $ResourceGroup -o json | ConvertFrom-Json
$ikey = $ai.instrumentationKey
$aiId = $ai.id

Write-Host "== Logger applicationInsights no APIM ==" -ForegroundColor Cyan
Invoke-ArmPut "https://management.azure.com$apimId/loggers/appinsights?api-version=$apiVer" `
  @{ properties = @{ loggerType = 'applicationInsights'; resourceId = $aiId; credentials = @{ instrumentationKey = $ikey } } }

Write-Host "== Diagnostic da API -> App Insights ==" -ForegroundColor Cyan
Invoke-ArmPut "https://management.azure.com$apimId/apis/$ApiPath/diagnostics/applicationinsights?api-version=$apiVer" `
  @{ properties = @{ loggerId = "$apimId/loggers/appinsights"; alwaysLog = 'allErrors'; sampling = @{ samplingType = 'fixed'; percentage = 100 } } }

Write-Host "== Alerta de erros 4xx (429/403) ==" -ForegroundColor Cyan
$alertName = 'alert-genai-4xx'
if (-not (az monitor metrics alert show -n $alertName -g $ResourceGroup --query id -o tsv 2>$null)) {
  az monitor metrics alert create -n $alertName -g $ResourceGroup --scopes $apimId `
    --condition "total Requests > 50 where GatewayResponseCodeCategory includes '4xx'" `
    --window-size 5m --evaluation-frequency 1m --severity 3 `
    --description "Pico de respostas 4xx no GenAI Gateway (rate limit/quota de token)" -o none
}
Write-Host "`nOK. Camada 3 observavel. Teste o gateway com 05-connect-playground.ps1." -ForegroundColor Green
