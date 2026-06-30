#Requires -Version 7.0
<#
  Camada 3 - orquestrador. Encadeia os passos 01 -> 02 -> 03 -> 04 -> 06.
  O passo 05 (conexao do Playground) e informativo: rode depois com o time desejado.

  Pre-requisitos:
    - az login com permissao para criar APIM e atribuir RBAC no Foundry.
    - PowerShell 7+.
    - teams.json criado (copie de teams.example.json e ajuste os limites).

  Exemplo:
    ./deploy-layer3.ps1 -SubscriptionId <SUB> -ResourceGroup rg-foundry-gw-01 -Location eastus2 `
      -ApimName apim-foundry-gw-01 -PublisherName "Plataforma" -PublisherEmail plataforma@empresa.com `
      -FoundryName meu-foundry -FoundryResourceGroup rg-foundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$Location,
  [Parameter(Mandatory)][string]$ApimName,
  [Parameter(Mandatory)][string]$PublisherName,
  [Parameter(Mandatory)][string]$PublisherEmail,
  [Parameter(Mandatory)][string]$FoundryName,
  [Parameter(Mandatory)][string]$FoundryResourceGroup,
  [string]$Sku = 'StandardV2',
  [int]$Capacity = 1,
  [string]$ApiPath = 'foundry',
  [string]$TeamsFile = ''
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $TeamsFile) { $TeamsFile = Join-Path $here 'teams.json' }

Write-Host "########## Camada 3 - Passo 1/5: provisionar APIM ##########" -ForegroundColor Magenta
& (Join-Path $here '01-deploy-apim.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
  -Location $Location -ApimName $ApimName -PublisherName $PublisherName -PublisherEmail $PublisherEmail `
  -Sku $Sku -Capacity $Capacity

Write-Host "########## Camada 3 - Passo 2/5: ligar ao Foundry ##########" -ForegroundColor Magenta
& (Join-Path $here '02-wire-foundry.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
  -ApimName $ApimName -FoundryName $FoundryName -FoundryResourceGroup $FoundryResourceGroup -ApiPath $ApiPath

Write-Host "########## Camada 3 - Passo 3/5: policy de API (MI + emit-token-metric) ##########" -ForegroundColor Magenta
& (Join-Path $here '03-apply-token-policy.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
  -ApimName $ApimName -ApiPath $ApiPath

Write-Host "########## Camada 3 - Passo 4/5: products por time + llm-token-limit ##########" -ForegroundColor Magenta
& (Join-Path $here '04-create-products.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
  -ApimName $ApimName -ApiPath $ApiPath -TeamsFile $TeamsFile

Write-Host "########## Camada 3 - Passo 5/5: observabilidade ##########" -ForegroundColor Magenta
& (Join-Path $here '06-observability.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
  -ApimName $ApimName -ApiPath $ApiPath

Write-Host "`nCamada 3 concluida. Pegue a conexao do Playground com:" -ForegroundColor Green
Write-Host "  ./05-connect-playground.ps1 -Product team-dev" -ForegroundColor Green
