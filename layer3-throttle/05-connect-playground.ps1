#Requires -Version 7.0
<#
  Camada 3 - Passo 5: imprime os dados de conexao do gateway para o Playground / apps.
  O Playground do Foundry (ou o SDK AzureOpenAI) aponta para o endpoint do APIM, usando a
  chave de subscription do APIM (NAO a chave do Foundry). No estouro de TPM volta 429.

  Exemplo:
    ./05-connect-playground.ps1 -Product team-dev
#>
[CmdletBinding()]
param(
  [string]$Product = 'team-dev',
  [string]$OpenAIApiVersion = '2024-10-21'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$st = Get-GatewayState
if (-not $st.apimGatewayUrl) { throw "Rode 01-deploy-apim.ps1 antes (estado nao encontrado)." }
$apiPath = if ($st.apiPath) { $st.apiPath } else { 'foundry' }
$gateway = "$($st.apimGatewayUrl)/$apiPath"

$key = '<rode-o-04-create-products.ps1-para-gerar-a-chave>'
if ($st.products) {
  $p = $st.products | Where-Object product -eq $Product
  if ($p) { $key = $p.subscriptionKey }
}

Write-Host "== Conexao do gateway (Product: $Product) ==" -ForegroundColor Green
Write-Host "Endpoint base : $gateway"
Write-Host "Header chave  : api-key: $key"
Write-Host "               (compativel com o SDK AzureOpenAI / Foundry Playground)"
Write-Host ""
Write-Host "== Snippet Python (openai) ==" -ForegroundColor Cyan
@"
from openai import AzureOpenAI
client = AzureOpenAI(
    azure_endpoint="$gateway",
    api_key="$key",                 # subscription key do APIM (nao a do Foundry)
    api_version="$OpenAIApiVersion",
)
resp = client.chat.completions.create(
    model="<seu-deployment>",
    messages=[{"role": "user", "content": "ping pelo gateway"}],
)
print(resp.choices[0].message.content)
# No estouro de TPM o gateway responde HTTP 429 + header Retry-After.
"@ | Write-Host
