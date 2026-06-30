#Requires -Version 7.0
<#
  Camada 4 - Rollback. Remove o Budget. O Action Group so e removido com -RemoveActionGroup
  (ele pode estar compartilhado com a Camada 2).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [string]$BudgetName = 'budget-ai-sandbox',
  [string]$ActionGroupName = 'ag-cost-guardrails',
  [switch]$RemoveActionGroup
)
$ErrorActionPreference = 'Continue'
$apiVer = '2023-11-01'
az account set --subscription $SubscriptionId | Out-Null
$budgetId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Consumption/budgets/$BudgetName"

Write-Host "remove budget: $BudgetName"
az rest --method delete --uri "https://management.azure.com$budgetId?api-version=$apiVer" -o none 2>$null

if ($RemoveActionGroup) {
  Write-Host "remove action group: $ActionGroupName"
  az monitor action-group delete --name $ActionGroupName --resource-group $ResourceGroup 2>$null
}
Write-Host "Rollback da Camada 4 concluido."
