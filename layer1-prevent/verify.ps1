#Requires -Version 7.0
<#
  Camada 1 - Verificacao.
  Mostra a compliance dos assignments e PROVA que a trava de PTU bloqueia,
  tentando criar um deployment ProvisionedManaged (esperado: BLOQUEADO em modo Deny).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $FoundryAccount
)
$ErrorActionPreference = 'Continue'
az account set --subscription $SubscriptionId | Out-Null
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

Write-Host "== Assignments no RG ==" -ForegroundColor Cyan
az policy assignment list --scope $rgScope --query "[].{name:name, policy:policyDefinitionId}" -o table

Write-Host "== Compliance (pode levar minutos para popular) ==" -ForegroundColor Cyan
az policy state summarize --resource-group $ResourceGroup -o json

if ($FoundryAccount) {
  Write-Host "== Teste vivo: criar um deployment PTU (esperado: BLOQUEADO em Deny) ==" -ForegroundColor Cyan
  az cognitiveservices account deployment create --name $FoundryAccount --resource-group $ResourceGroup --deployment-name test-ptu-should-fail --model-name gpt-4o --model-version "2024-08-06" --model-format OpenAI --sku-name ProvisionedManaged --sku-capacity 1 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "OK: bloqueado pela policy (esperado)." -ForegroundColor Green }
  else { Write-Host "ATENCAO: NAO foi bloqueado. Confirme que -Effect Deny foi aplicado." -ForegroundColor Red }
}
