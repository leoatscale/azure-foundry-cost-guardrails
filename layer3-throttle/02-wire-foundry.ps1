#Requires -Version 7.0
<#
  Camada 3 - Passo 2: liga o APIM ao Foundry existente.
  - Atribui 'Cognitive Services OpenAI User' a Managed Identity do APIM no Foundry (auth sem chave).
  - Cria a API pass-through no APIM apontando para o endpoint de inferencia do Foundry.
  - Cria operacoes wildcard (/*) para repassar qualquer rota (chat/completions, embeddings, etc.).

  Exemplo:
    ./02-wire-foundry.ps1 -SubscriptionId <SUB> -ResourceGroup rg-foundry-gw-01 -ApimName apim-foundry-gw-01 `
       -FoundryName meu-foundry -FoundryResourceGroup rg-foundry -ApiPath foundry
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$ApimName,
  [Parameter(Mandatory)][string]$FoundryName,
  [Parameter(Mandatory)][string]$FoundryResourceGroup,
  [string]$ApiPath = 'foundry'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$st = Get-GatewayState
if (-not $st.apimPrincipalId) { throw "Rode 01-deploy-apim.ps1 antes (estado nao encontrado)." }
$principalId = $st.apimPrincipalId

az account set --subscription $SubscriptionId | Out-Null

Write-Host "== Foundry endpoint/id ==" -ForegroundColor Cyan
$foundry = az cognitiveservices account show -n $FoundryName -g $FoundryResourceGroup -o json | ConvertFrom-Json
$foundryId = $foundry.id
$endpoint  = $foundry.properties.endpoint.TrimEnd('/')

Write-Host "== RBAC: Cognitive Services OpenAI User -> MI do APIM ==" -ForegroundColor Cyan
$existing = az role assignment list --assignee $principalId --scope $foundryId `
  --query "[?roleDefinitionName=='Cognitive Services OpenAI User'] | [0].id" -o tsv 2>$null
if (-not $existing) {
  az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
    --role "Cognitive Services OpenAI User" --scope $foundryId -o none
  Write-Host "Role atribuida (aguarde propagacao)." -ForegroundColor Yellow
} else { Write-Host "Role ja atribuida." -ForegroundColor Green }

Write-Host "== API pass-through '$ApiPath' no APIM ==" -ForegroundColor Cyan
if (-not (az apim api show -g $ResourceGroup --service-name $ApimName --api-id $ApiPath --query name -o tsv 2>$null)) {
  az apim api create -g $ResourceGroup --service-name $ApimName --api-id $ApiPath `
    --path $ApiPath --display-name "Foundry Inference" `
    --service-url "$endpoint/openai" --protocols https --subscription-required true `
    --subscription-key-header-name "api-key" --subscription-key-query-param-name "api-key" -o none
} else {
  Write-Host "API ja existe - garantindo header 'api-key'." -ForegroundColor Green
  az apim api update -g $ResourceGroup --service-name $ApimName --api-id $ApiPath `
    --subscription-key-header-name "api-key" --subscription-key-query-param-name "api-key" -o none
}

Write-Host "== Operacoes wildcard (catch-all) ==" -ForegroundColor Cyan
foreach ($m in @("POST","GET")) {
  $opId = "$($m.ToLower())-all"
  if (-not (az apim api operation show -g $ResourceGroup --service-name $ApimName --api-id $ApiPath --operation-id $opId --query name -o tsv 2>$null)) {
    az apim api operation create -g $ResourceGroup --service-name $ApimName --api-id $ApiPath `
      --operation-id $opId --display-name "$m passthrough" --method $m --url-template "/*" -o none
    Write-Host "  + operacao $opId ($m /*)" -ForegroundColor Yellow
  } else { Write-Host "  operacao $opId ja existe." -ForegroundColor Green }
}

Save-GatewayState @{ foundryId = $foundryId; foundryEndpoint = $endpoint; apiPath = $ApiPath }
Write-Host "`nOK. Prossiga: 03-apply-token-policy.ps1" -ForegroundColor Green
