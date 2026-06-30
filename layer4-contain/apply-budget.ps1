#Requires -Version 7.0
<#
  Camada 4 - Conter por orcamento (reacao em horas).
  Cria um Budget no escopo do Resource Group com faixas 50/75/90/100% (custo real) mais
  uma faixa de 100% por forecast, ligado a um Action Group (email). O Action Group e o
  ponto onde voce pluga depois um Runbook de contencao (ver runbook-contain.example.ps1).

  HONESTIDADE: Budget e alerta + automacao reativa, NAO um freio nativo. O dado de custo
  leva horas para consolidar. Esta e a ultima linha de defesa, nao a principal.

  Pre-requisitos: az login + permissao de leitura de custo no escopo + Monitoring Contributor.

  Exemplo:
    ./apply-budget.ps1 -SubscriptionId <SUB> -ResourceGroup rg-dev-sandbox-01 -Amount 500 -AlertEmail voce@empresa.com
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$AlertEmail,
  [double]$Amount = 500,
  [string]$BudgetName = 'budget-ai-sandbox',
  [string]$ActionGroupName = 'ag-cost-guardrails',
  [int[]] $ActualThresholds   = @(50,75,90,100),
  [int[]] $ForecastThresholds = @(100),
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$apiVer = '2023-11-01'
$rgScope  = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$budgetId = "$rgScope/providers/Microsoft.Consumption/budgets/$BudgetName"

function Invoke-Az([string[]] $CliArgs) {
  if ($DryRun) { Write-Host "DRYRUN> az $($CliArgs -join ' ')" -ForegroundColor DarkYellow; return }
  $out = az @CliArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha no az: $($CliArgs -join ' ') :: $out" }
  return $out
}

$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Rode 'az login' antes de executar." }
Invoke-Az @('account','set','--subscription',$SubscriptionId) | Out-Null
Write-Host "Camada 4 - Conter. RG=$ResourceGroup  Amount=$Amount  Email=$AlertEmail" -ForegroundColor Cyan

# 1) Action Group (idempotente). Reaproveita o da Camada 2 se ja existir com o mesmo nome.
Write-Host "==> Action Group '$ActionGroupName'" -ForegroundColor Cyan
Invoke-Az @('monitor','action-group','create','--name',$ActionGroupName,'--resource-group',$ResourceGroup,
  '--short-name','CostGuard','--action','email','devowner',$AlertEmail) | Out-Null
$agId = if ($DryRun) { '<action-group-id>' } else { az monitor action-group show --name $ActionGroupName --resource-group $ResourceGroup --query id -o tsv }

# 2) Janela do budget: inicio no primeiro dia do mes corrente (UTC), fim em +5 anos.
$start = (Get-Date).ToUniversalTime().ToString('yyyy-MM-01T00:00:00Z')
$end   = (Get-Date).ToUniversalTime().AddYears(5).ToString('yyyy-MM-01T00:00:00Z')

# 3) Notificacoes 50/75/90/100 (Actual) + forecast.
$notifications = @{}
foreach ($t in $ActualThresholds) {
  $notifications["actual-$t"] = @{
    enabled = $true; operator = 'GreaterThanOrEqualTo'; threshold = $t; thresholdType = 'Actual'
    contactEmails = @($AlertEmail); contactGroups = @($agId)
  }
}
foreach ($t in $ForecastThresholds) {
  $notifications["forecast-$t"] = @{
    enabled = $true; operator = 'GreaterThanOrEqualTo'; threshold = $t; thresholdType = 'Forecasted'
    contactEmails = @($AlertEmail); contactGroups = @($agId)
  }
}

$body = @{
  properties = @{
    category   = 'Cost'
    amount     = $Amount
    timeGrain  = 'Monthly'
    timePeriod = @{ startDate = $start; endDate = $end }
    notifications = $notifications
  }
}

Write-Host "==> Budget '$BudgetName' (RG scope, $($ActualThresholds -join '/')% + forecast $($ForecastThresholds -join '/')%)" -ForegroundColor Cyan
if ($DryRun) {
  Write-Host "DRYRUN> PUT https://management.azure.com$budgetId?api-version=$apiVer" -ForegroundColor DarkYellow
  $body | ConvertTo-Json -Depth 8
} else {
  $f = [System.IO.Path]::GetTempFileName()
  [System.IO.File]::WriteAllText($f, ($body | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  try {
    az rest --method put --uri "https://management.azure.com$budgetId?api-version=$apiVer" `
      --headers "Content-Type=application/json" "Accept=application/json" --body "@$f" -o none
    if ($LASTEXITCODE -ne 0) { throw "Falha ao criar o budget." }
  } finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "OK. Camada 4 ativa: budget de $Amount no RG, alertas em $($ActualThresholds -join '/')% + forecast." -ForegroundColor Green
Write-Host "Para contencao automatica, hospede runbook-contain.example.ps1 num Automation Account e" -ForegroundColor Green
Write-Host "adicione-o como acao 'Automation Runbook' no Action Group '$ActionGroupName'." -ForegroundColor Green
