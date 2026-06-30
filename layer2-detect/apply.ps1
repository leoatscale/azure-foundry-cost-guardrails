#Requires -Version 7.0
<#
  Camada 2 - Detectar (reacao em minutos).
  Cria um Action Group (email) + um Activity Log Alert que dispara no minuto em que um
  novo deployment de IA e criado no RG. Cobre o intervalo antes do custo aparecer no
  Cost Management (que leva horas para consolidar).

  Pre-requisitos: az login + permissao de Monitoring Contributor (ou Contributor) no RG.

  Exemplo:
    ./apply.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -AlertEmail voce@empresa.com
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $AlertEmail,
  [string] $ActionGroupName = 'ag-cost-guardrails',
  [string] $AlertName       = 'alert-ai-deployment-write',
  [ValidateSet('accountbased','hubbased')] [string] $Scenario = 'accountbased',
  [switch] $DryRun
)
$ErrorActionPreference = 'Stop'
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

function Invoke-Az([string[]] $CliArgs) {
  if ($DryRun) { Write-Host "DRYRUN> az $($CliArgs -join ' ')" -ForegroundColor DarkYellow; return }
  $out = az @CliArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha no az: $($CliArgs -join ' ') :: $out" }
  return $out
}

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Rode 'az login' antes de executar." }
Invoke-Az @('account','set','--subscription',$SubscriptionId) | Out-Null
Write-Host "Camada 2 - Detectar. RG=$ResourceGroup  Email=$AlertEmail" -ForegroundColor Cyan

# 1) Action Group (email)
Write-Host "==> Action Group '$ActionGroupName'" -ForegroundColor Cyan
Invoke-Az @('monitor','action-group','create','--name',$ActionGroupName,'--resource-group',$ResourceGroup,
  '--short-name','CostGuard','--action','email','devowner',$AlertEmail) | Out-Null

# 2) Activity Log Alert: dispara na criacao de deployment de IA no RG.
# account-based: Microsoft.CognitiveServices/accounts/deployments/write
# hub-based: tambem cobre Microsoft.MachineLearningServices (compute/endpoints).
if (-not $DryRun) {
  $agId = az monitor action-group show --name $ActionGroupName --resource-group $ResourceGroup --query id -o tsv

  Write-Host "==> Activity Log Alert '$AlertName' (deployment de IA)" -ForegroundColor Cyan
  Invoke-Az @('monitor','activity-log','alert','create','--name',$AlertName,
    '--resource-group',$ResourceGroup,'--scope',$rgScope,
    '--condition','category=Administrative and operationName=Microsoft.CognitiveServices/accounts/deployments/write',
    '--action-group',$agId,
    '--description','Camada 2: novo deployment de IA criado no RG sandbox.') | Out-Null

  if ($Scenario -eq 'hubbased') {
    Write-Host "==> Activity Log Alert hub-based (compute do AML)" -ForegroundColor Cyan
    Invoke-Az @('monitor','activity-log','alert','create','--name',"$AlertName-aml",
      '--resource-group',$ResourceGroup,'--scope',$rgScope,
      '--condition','category=Administrative and operationName=Microsoft.MachineLearningServices/workspaces/computes/write',
      '--action-group',$agId,
      '--description','Camada 2: novo compute de AML (possivel GPU) criado no RG sandbox.') | Out-Null
  }
}

Write-Host ""
Write-Host "OK. Camada 2 ativa: email para $AlertEmail a cada novo deployment de IA no RG." -ForegroundColor Green
Write-Host "Dica de varredura sob demanda (Resource Graph):" -ForegroundColor Green
Write-Host "  az graph query -q \"resources | where resourceGroup =~ '$ResourceGroup' | where type startswith 'microsoft.cognitiveservices' or type startswith 'microsoft.machinelearningservices'\"" -ForegroundColor DarkGray
