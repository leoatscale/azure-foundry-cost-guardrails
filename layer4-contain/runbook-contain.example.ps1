#Requires -Version 7.0
<#
  Camada 4 - Runbook de contencao (EXEMPLO, opcional, destrutivo).

  Acao reativa que o Budget pode disparar quando o gasto passa do teto: apaga os deployments
  de IA do RG (a forma que queima dinheiro: PTU/provisionado e consumo). E a rede de seguranca
  final, nao o freio principal (as Camadas 1 e 3 ja deviam ter evitado o estouro).

  COMO USAR EM PRODUCAO:
    1. Crie um Automation Account com Managed Identity.
    2. De a essa identidade permissao no RG sandbox (ex.: 'Cognitive Services Contributor'
       limitado ao RG, ou a custom role com deployments/delete).
    3. Importe este script como um Runbook (PowerShell 7.2) e publique.
    4. Crie um webhook do Runbook e adicione-o como acao 'Automation Runbook' no Action Group
       'ag-cost-guardrails' (o mesmo do apply-budget.ps1).
    Assim, ao bater 100% do budget, o Action Group dispara o Runbook automaticamente.

  Em producao, troque o bloco de login pelo Connect-AzAccount -Identity (Managed Identity).
  Aqui usamos az CLI para manter o exemplo simples e rodavel localmente com -WhatIfOnly.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'
az account set --subscription $SubscriptionId | Out-Null
Write-Host "Camada 4 - contencao no RG=$ResourceGroup (WhatIfOnly=$($WhatIfOnly.IsPresent))" -ForegroundColor Cyan

# Lista as contas Cognitive Services / Foundry (account-based) do RG.
$accounts = az cognitiveservices account list -g $ResourceGroup --query "[].name" -o tsv 2>$null
if (-not $accounts) { Write-Host "Nenhuma conta Cognitive Services no RG. Nada a conter."; return }

foreach ($acc in $accounts) {
  $deployments = az cognitiveservices account deployment list -n $acc -g $ResourceGroup --query "[].name" -o tsv 2>$null
  foreach ($dep in $deployments) {
    if ($WhatIfOnly) {
      Write-Host "WHATIF> apagaria deployment '$dep' da conta '$acc'" -ForegroundColor DarkYellow
    } else {
      Write-Host "apagando deployment '$dep' da conta '$acc'..." -ForegroundColor Yellow
      az cognitiveservices account deployment delete -n $acc -g $ResourceGroup --deployment-name $dep -o none
    }
  }
}
Write-Host "Contencao concluida." -ForegroundColor Green
