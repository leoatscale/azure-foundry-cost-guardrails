#Requires -Version 7.0
<#
  Camada 3 - Passo 1: provisiona APIM + Log Analytics + App Insights (idempotente).
  APIM e o ponto onde a policy llm-token-limit corta o consumo de token em tempo real.

  Exemplo:
    ./01-deploy-apim.ps1 -SubscriptionId <SUB> -ResourceGroup rg-foundry-gw-01 -Location eastus2 `
       -ApimName apim-foundry-gw-01 -PublisherName "Plataforma" -PublisherEmail plataforma@empresa.com
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$Location,
  [Parameter(Mandatory)][string]$ApimName,
  [Parameter(Mandatory)][string]$PublisherName,
  [Parameter(Mandatory)][string]$PublisherEmail,
  [string]$Sku = 'StandardV2',
  [int]$Capacity = 1,
  [string]$LogAnalytics = '',
  [string]$AppInsights  = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
if (-not $LogAnalytics) { $LogAnalytics = "log-$ApimName" }
if (-not $AppInsights)  { $AppInsights  = "appi-$ApimName" }
$apiVer = '2023-05-01-preview'
$apimArmId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"

az account set --subscription $SubscriptionId | Out-Null

Write-Host "== Resource group $ResourceGroup ==" -ForegroundColor Cyan
az group create -n $ResourceGroup -l $Location -o none

Write-Host "== Log Analytics $LogAnalytics ==" -ForegroundColor Cyan
if (-not (az monitor log-analytics workspace show -g $ResourceGroup -n $LogAnalytics --query id -o tsv 2>$null)) {
  az monitor log-analytics workspace create -g $ResourceGroup -n $LogAnalytics -l $Location -o none
}
$lawId = az monitor log-analytics workspace show -g $ResourceGroup -n $LogAnalytics --query id -o tsv

Write-Host "== App Insights $AppInsights ==" -ForegroundColor Cyan
az extension add -n application-insights --only-show-errors 2>$null | Out-Null
if (-not (az monitor app-insights component show --app $AppInsights -g $ResourceGroup --query id -o tsv 2>$null)) {
  az monitor app-insights component create --app $AppInsights -g $ResourceGroup -l $Location --workspace $lawId -o none
}

Write-Host "== APIM $ApimName ($Sku) ==" -ForegroundColor Cyan
# az apim create nao suporta as tiers v2 (StandardV2/BasicV2/PremiumV2) em CLIs atuais.
# Para v2, cria via ARM REST. Para tiers classicas, usa az apim create.
$isV2 = $Sku -match 'V2$'
if (-not (az apim show -n $ApimName -g $ResourceGroup --query name -o tsv 2>$null)) {
  Write-Host "Criando APIM $Sku (pode levar minutos)..." -ForegroundColor Yellow
  if ($isV2) {
    Invoke-ArmPut "https://management.azure.com$($apimArmId)?api-version=$apiVer" @{
      location   = $Location
      sku        = @{ name = $Sku; capacity = $Capacity }
      identity   = @{ type = 'SystemAssigned' }
      properties = @{ publisherEmail = $PublisherEmail; publisherName = $PublisherName }
    }
    do {
      Start-Sleep -Seconds 30
      $state = az rest --method get --uri "https://management.azure.com$($apimArmId)?api-version=$apiVer" --query properties.provisioningState -o tsv 2>$null
      Write-Host "  provisioningState=$state"
    } while ($state -in @('Activating','Created','Updating',''))
  } else {
    az apim create -n $ApimName -g $ResourceGroup -l $Location `
      --sku-name $Sku --sku-capacity $Capacity `
      --publisher-email $PublisherEmail --publisher-name $PublisherName -o none
  }
} else { Write-Host "APIM ja existe." -ForegroundColor Green }

Write-Host "== Identidade gerenciada / endpoints ==" -ForegroundColor Cyan
$apimId = az apim show -n $ApimName -g $ResourceGroup --query id -o tsv
$principalId = az apim show -n $ApimName -g $ResourceGroup --query identity.principalId -o tsv 2>$null
if (-not $principalId) {
  Invoke-ArmPut "https://management.azure.com$($apimId)?api-version=$apiVer" @{ identity = @{ type = 'SystemAssigned' } }
  $principalId = az apim show -n $ApimName -g $ResourceGroup --query identity.principalId -o tsv
}
$gatewayUrl = az apim show -n $ApimName -g $ResourceGroup --query gatewayUrl -o tsv

Save-GatewayState @{
  subscriptionId = $SubscriptionId; resourceGroup = $ResourceGroup; apimName = $ApimName
  apimId = $apimId; apimPrincipalId = $principalId; apimGatewayUrl = $gatewayUrl
  appInsights = $AppInsights; apiVersion = $apiVer
}
Write-Host "`nOK. apimGatewayUrl=$gatewayUrl  principalId=$principalId" -ForegroundColor Green
Write-Host "Estado salvo em layer3-throttle/.state.json. Prossiga: 02-wire-foundry.ps1" -ForegroundColor Green
