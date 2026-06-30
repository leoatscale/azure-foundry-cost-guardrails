#Requires -Version 7.0
<#
  Camada 2 - Rollback.
  Remove os Activity Log Alerts e o Action Group criados pelo apply.ps1.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $ActionGroupName = 'ag-cost-guardrails',
  [string] $AlertName       = 'alert-ai-deployment-write'
)
$ErrorActionPreference = 'Continue'
az account set --subscription $SubscriptionId | Out-Null

foreach ($n in @($AlertName, "$AlertName-aml")) {
  Write-Host "remove activity-log alert: $n"
  az monitor activity-log alert delete --name $n --resource-group $ResourceGroup 2>$null
}
Write-Host "remove action group: $ActionGroupName"
az monitor action-group delete --name $ActionGroupName --resource-group $ResourceGroup 2>$null
Write-Host "Rollback da Camada 2 concluido."
