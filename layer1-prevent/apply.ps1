#Requires -Version 7.0
<#
  Camada 1 - Prevenir (control plane).
  Aplica as travas de governanca de custo de IA num Resource Group de desenvolvedor:
  Azure Policy (Audit/Deny) + custom role de least privilege.

  Pre-requisitos:
    - Azure CLI logado:  az login
    - Permissao no escopo: Owner OU (Resource Policy Contributor + User Access Administrator)
    - PowerShell 7+

  IMPORTANTE: nada e fixo no ambiente. Subscription, RG, regiao e cenario vem por parametro.

  Exemplos:
    # 1) SEMPRE comece em Audit (observa, nao bloqueia nada)
    ./apply.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Location eastus -Scenario accountbased -Effect Audit

    # 2) Revisada a compliance no portal, vire para Deny
    ./apply.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Location eastus -Scenario accountbased -Effect Deny

    # 3) (Opcional) reativar a allow-list de modelos por publisher (bloqueia Fireworks e terceiros)
    ./apply.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Location eastus -Effect Deny -EnableApprovedModels
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]   $SubscriptionId,
  [Parameter(Mandatory)] [string]   $ResourceGroup,
  [Parameter(Mandatory)] [string]   $Location,
  [ValidateSet('accountbased','hubbased')] [string] $Scenario = 'accountbased',
  [ValidateSet('Audit','Deny','Disabled')] [string] $Effect   = 'Audit',
  [string[]] $AllowedLocations  = @(),
  [string[]] $AllowedSkus       = @('Standard','GlobalStandard','DataZoneStandard'),
  [string[]] $AllowedPublishers = @('OpenAI','Microsoft'),
  [switch]   $EnableApprovedModels,
  [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$subScope = "/subscriptions/$SubscriptionId"
$rgScope  = "$subScope/resourceGroups/$ResourceGroup"
if (-not $AllowedLocations -or $AllowedLocations.Count -eq 0) { $AllowedLocations = @($Location) }

# IDs de policy BUILT-IN do Azure (globais, iguais em qualquer tenant)
$BUILTIN = @{
  AllowedTypes     = '/providers/Microsoft.Authorization/policyDefinitions/a08ec900-254a-4555-9bf5-e42af04b5c5c'
  AllowedLocations = '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
  DisableLocalAuth = '/providers/Microsoft.Authorization/policyDefinitions/71ef260a-8f18-47b7-abcb-62d0673d94dc'
  RestrictNetwork  = '/providers/Microsoft.Authorization/policyDefinitions/037eea7a-bd0a-46c5-9a66-03aea78705d3'
  ApprovedModels   = '/providers/Microsoft.Authorization/policyDefinitions/aafe3651-cb78-4f68-9f81-e7e41509110f'
  ManagedIdentity  = '/providers/Microsoft.Authorization/policyDefinitions/fe3fd216-4f83-4fc1-8984-2bbec80a3418'
}

function Invoke-Az([string[]] $CliArgs) {
  if ($DryRun) { Write-Host "DRYRUN> az $($CliArgs -join ' ')" -ForegroundColor DarkYellow; return }
  $out = az @CliArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Falha no az: $($CliArgs -join ' ') :: $out" }
  return $out
}

function Assign([string] $Name, [string] $PolicyId, $ParamsObj) {
  $cli = @('policy','assignment','create','--name',$Name,'--scope',$rgScope,'--policy',$PolicyId)
  $tmp = $null
  if ($ParamsObj) {
    $tmp = [System.IO.Path]::GetTempFileName()
    ($ParamsObj | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding utf8
    $cli += @('--params', $tmp)
  }
  try { Invoke-Az $cli | Out-Null; Write-Host "  assign: $Name" -ForegroundColor DarkGray }
  finally { if ($tmp) { Remove-Item $tmp -ErrorAction SilentlyContinue } }
}

# Preflight
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Rode 'az login' antes de executar." }
Invoke-Az @('account','set','--subscription',$SubscriptionId) | Out-Null
Write-Host "Camada 1 - Prevenir. Cenario=$Scenario  Effect=$Effect  RG=$ResourceGroup  Regiao=$Location" -ForegroundColor Cyan

# 1) Definicoes CUSTOM (so o que NAO tem built-in) -- criadas no nivel da subscription.
# IMPORTANTE: o az espera --rules = APENAS o policyRule e --params = APENAS as parameter
# definitions. Os arquivos do repo sao definicoes COMPLETAS (para importar no portal tambem),
# entao extraimos cada parte e gravamos em arquivos temporarios.
function DefineCustom([string] $Name, [string] $RelFile) {
  if ($DryRun) { Write-Host "DRYRUN> definir policy $Name a partir de $RelFile" -ForegroundColor DarkYellow; return }
  $def  = Get-Content (Join-Path $here $RelFile) -Raw | ConvertFrom-Json
  $p    = $def.properties
  $mode = if ($p.mode) { $p.mode } else { 'All' }
  $ruleTmp  = [System.IO.Path]::GetTempFileName()
  $paramTmp = [System.IO.Path]::GetTempFileName()
  ($p.policyRule | ConvertTo-Json -Depth 30) | Set-Content -Path $ruleTmp  -Encoding utf8
  ($p.parameters | ConvertTo-Json -Depth 30) | Set-Content -Path $paramTmp -Encoding utf8
  try {
    Invoke-Az @('policy','definition','create','--name',$Name,'--mode',$mode,
      '--display-name',$p.displayName,'--description',$p.description,
      '--subscription',$SubscriptionId,'--rules',$ruleTmp,'--params',$paramTmp) | Out-Null
    Write-Host "  define: $Name" -ForegroundColor DarkGray
  } finally { Remove-Item $ruleTmp,$paramTmp -ErrorAction SilentlyContinue }
}

Write-Host "==> Definicoes custom" -ForegroundColor Cyan
DefineCustom 'deny-foundry-sku-ptu' 'policies/definitions/deny-deployment-sku.json'
if ($Scenario -eq 'hubbased') {
  DefineCustom 'deny-ml-gpu-compute'         'policies/definitions/deny-gpu-mlcompute.json'
  DefineCustom 'deny-ml-serverless-mktplace' 'policies/definitions/deny-serverless-marketplace.json'
}

# 2) Allowed resource types + locations (built-ins Deny-only). Em RG novo/vazio, seguro aplicar ja.
Write-Host "==> Allowed types + locations (Deny-only)" -ForegroundColor Cyan
$typesFile = Join-Path $here "policies/params/allowed-resource-types.$Scenario.json"
Invoke-Az @('policy','assignment','create','--name','allowed-types','--scope',$rgScope,
  '--policy',$BUILTIN.AllowedTypes,'--params',$typesFile) | Out-Null
Assign 'allowed-locations' $BUILTIN.AllowedLocations @{ listOfAllowedLocations = @{ value = $AllowedLocations } }

# 3) Built-ins do AI Services (suportam Audit/Deny pelo parametro effect)
Write-Host "==> Built-ins AI Services (effect=$Effect)" -ForegroundColor Cyan
Assign 'deny-localauth'   $BUILTIN.DisableLocalAuth @{ effect = @{ value = $Effect } }
Assign 'restrict-network' $BUILTIN.RestrictNetwork  @{ effect = @{ value = $Effect } }
Assign 'require-mi'       $BUILTIN.ManagedIdentity  @{ effect = @{ value = $Effect } }

# approved-models e OPCIONAL (off por default). Quando ligado, bloqueia Fireworks e publishers de terceiro.
if ($EnableApprovedModels) {
  Assign 'approved-models' $BUILTIN.ApprovedModels @{
    effect            = @{ value = $Effect }
    allowedPublishers = @{ value = $AllowedPublishers }
    allowedAssetIds   = @{ value = @() }
  }
} else {
  Write-Host "  approved-models DESLIGADO (terceiros liberados; a trava de SKU/PTU ainda barra a forma por hora)" -ForegroundColor Yellow
}

# 4) Custom: trava de custo central (SKU/PTU) + customs de hub-based
Write-Host "==> Assignments custom (effect=$Effect)" -ForegroundColor Cyan
function DefId([string] $n) { "$subScope/providers/Microsoft.Authorization/policyDefinitions/$n" }
Assign 'deny-sku-ptu' (DefId 'deny-foundry-sku-ptu') @{ effect = @{ value = $Effect }; allowedSkus = @{ value = $AllowedSkus } }
if ($Scenario -eq 'hubbased') {
  Assign 'deny-gpu-compute' (DefId 'deny-ml-gpu-compute')         @{ effect = @{ value = $Effect } }
  Assign 'deny-serverless'  (DefId 'deny-ml-serverless-mktplace') @{ effect = @{ value = $Effect } }
}

# 5) Custom role safe-dev -- injeta o AssignableScope a partir da subscription (nada fixo no JSON)
Write-Host "==> Custom role 'AI Sandbox Safe Dev'" -ForegroundColor Cyan
if (-not $DryRun) {
  $role = Get-Content (Join-Path $here 'rbac/role-ai-sandbox-safe-dev.json') -Raw | ConvertFrom-Json
  $role.AssignableScopes = @($subScope)
  $rtmp = [System.IO.Path]::GetTempFileName()
  ($role | ConvertTo-Json -Depth 12) | Set-Content -Path $rtmp -Encoding utf8
  $exists = az role definition list --name $role.Name --query "[0].roleName" -o tsv
  if ($exists) { az role definition update --role-definition $rtmp | Out-Null }
  else         { az role definition create --role-definition $rtmp | Out-Null }
  Remove-Item $rtmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "OK. Camada 1 aplicada em modo $Effect." -ForegroundColor Green
Write-Host "Proximos passos da defesa em profundidade:" -ForegroundColor Green
Write-Host "  - Camada 2 (deteccao): layer2-detect/apply.ps1 -AlertEmail voce@empresa.com" -ForegroundColor Green
Write-Host "  - Camada 3 (throttle de token): layer3-throttle/deploy-layer3.ps1 (APIM na frente do Foundry)" -ForegroundColor Green
Write-Host "  - Camada 4 (orcamento): layer4-contain/apply-budget.ps1 -Amount 500 -AlertEmail voce@empresa.com" -ForegroundColor Green
Write-Host "  - Atribuir 'AI Sandbox Safe Dev' ao dev no RG e remover Owner/Contributor (ver README, secao 8.1)" -ForegroundColor Green
Write-Host "  - Zerar quota de PTU e de GPU vCPU na regiao $Location (ver README, secao 8.6)" -ForegroundColor Green
Write-Host "  - Fechar o bypass do Foundry: disableLocalAuth, publicNetworkAccess=Disabled, Private Endpoint (ver README, secao 8.7)" -ForegroundColor Green
