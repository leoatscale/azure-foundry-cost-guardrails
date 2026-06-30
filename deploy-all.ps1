#Requires -Version 7.0
<#
  deploy-all.ps1 - orquestrador das camadas com escopo de Resource Group (1, 2 e 4).
  A Camada 3 (APIM / GenAI Gateway) tem seu proprio orquestrador, porque depende dos dados
  do Foundry e do APIM: rode layer3-throttle/deploy-layer3.ps1 separadamente.

  Ordem recomendada de adocao:
    1. Rode aqui com -Effect Audit (observa, nao bloqueia).
    2. Revise a conformidade (layer1-prevent/verify.ps1) e a deteccao.
    3. Rode de novo com -Effect Deny.
    4. Rode a Camada 3 (gateway) quando for colocar o APIM na frente do Foundry.

  Exemplo:
    ./deploy-all.ps1 -SubscriptionId <SUB> -ResourceGroup rg-dev-sandbox-01 -Location eastus `
      -Scenario accountbased -Effect Audit -AlertEmail voce@empresa.com -BudgetAmount 500
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$Location,
  [Parameter(Mandatory)][string]$AlertEmail,
  [ValidateSet('accountbased','hubbased')][string]$Scenario = 'accountbased',
  [ValidateSet('Audit','Deny','Disabled')][string]$Effect = 'Audit',
  [double]$BudgetAmount = 500,
  [switch]$EnableApprovedModels,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

Write-Host "########## Camada 1 - Prevenir (Effect=$Effect) ##########" -ForegroundColor Magenta
$l1 = @{ SubscriptionId=$SubscriptionId; ResourceGroup=$ResourceGroup; Location=$Location; Scenario=$Scenario; Effect=$Effect }
if ($EnableApprovedModels) { $l1.EnableApprovedModels = $true }
if ($DryRun) { $l1.DryRun = $true }
& (Join-Path $here 'layer1-prevent/apply.ps1') @l1

Write-Host "########## Camada 2 - Detectar ##########" -ForegroundColor Magenta
$l2 = @{ SubscriptionId=$SubscriptionId; ResourceGroup=$ResourceGroup; AlertEmail=$AlertEmail; Scenario=$Scenario }
if ($DryRun) { $l2.DryRun = $true }
& (Join-Path $here 'layer2-detect/apply.ps1') @l2

Write-Host "########## Camada 4 - Conter por orcamento ##########" -ForegroundColor Magenta
$l4 = @{ SubscriptionId=$SubscriptionId; ResourceGroup=$ResourceGroup; AlertEmail=$AlertEmail; Amount=$BudgetAmount }
if ($DryRun) { $l4.DryRun = $true }
& (Join-Path $here 'layer4-contain/apply-budget.ps1') @l4

Write-Host "`nCamadas 1, 2 e 4 aplicadas (Effect=$Effect)." -ForegroundColor Green
Write-Host "Faltam (passos manuais e gateway):" -ForegroundColor Green
Write-Host "  - Atribuir a custom role 'AI Sandbox Safe Dev' ao dev e remover Owner/Contributor (README 8.1)." -ForegroundColor Green
Write-Host "  - Zerar quota de PTU/GPU e fechar bypass do Foundry (README 8.5)." -ForegroundColor Green
Write-Host "  - Camada 3 (APIM): layer3-throttle/deploy-layer3.ps1 (README 8.3)." -ForegroundColor Green
Write-Host "  - Quando confortavel com a conformidade em Audit, rode de novo com -Effect Deny." -ForegroundColor Green
