#Requires -Version 7.0
<#
  Camada 1 - Rollback.
  Remove tudo que o apply.ps1 criou (assignments + definicoes + custom role).
  Use o mesmo -Scenario do apply.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [ValidateSet('accountbased','hubbased')] [string] $Scenario = 'accountbased'
)
$ErrorActionPreference = 'Continue'
$subScope = "/subscriptions/$SubscriptionId"
$rgScope  = "$subScope/resourceGroups/$ResourceGroup"
az account set --subscription $SubscriptionId | Out-Null

$assignments = @('allowed-types','allowed-locations','deny-localauth','restrict-network','require-mi','approved-models','deny-sku-ptu')
if ($Scenario -eq 'hubbased') { $assignments += @('deny-gpu-compute','deny-serverless') }
foreach ($a in $assignments) {
  Write-Host "remove assignment: $a"
  az policy assignment delete --name $a --scope $rgScope 2>$null
}

$defs = @('deny-foundry-sku-ptu')
if ($Scenario -eq 'hubbased') { $defs += @('deny-ml-gpu-compute','deny-ml-serverless-mktplace') }
foreach ($d in $defs) {
  Write-Host "remove definition: $d"
  az policy definition delete --name $d --subscription $SubscriptionId 2>$null
}

Write-Host "remove custom role 'AI Sandbox Safe Dev' (so funciona se nao houver atribuicoes ativas)"
az role definition delete --name 'AI Sandbox Safe Dev' 2>$null
Write-Host "Rollback da Camada 1 concluido."
