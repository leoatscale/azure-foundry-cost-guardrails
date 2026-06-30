# Built-ins do AI Services x policies custom (reconciliacao)

Fonte: https://learn.microsoft.com/en-us/azure/ai-services/policy-reference

Regra: usar **built-in com effect Deny** sempre que existir (Microsoft mantem e versiona).
So manter custom onde NAO existe built-in. A trava de custo mais importante (SKU/PTU) e custom.

## Trocar custom -> built-in (Deny nativo)

| O que eu quero | Minha custom (deprecada) | Built-in para usar | DefinitionId | Effects |
|---|---|---|---|---|
| Fechar local auth (Entra-only) | policy-enforce-disablelocalauth.json | Azure AI Services resources should have key access disabled | 71ef260a-8f18-47b7-abcb-62d0673d94dc | Audit, **Deny**, Disabled |
| Bloquear rede publica | policy-deny-public-network.json | Azure AI Services resources should restrict network access | 037eea7a-bd0a-46c5-9a66-03aea78705d3 | Audit, **Deny**, Disabled |
| So modelos aprovados (mata Fireworks) | policy-deny-model.json | Foundry model deployments should only use approved models | aafe3651-cb78-4f68-9f81-e7e41509110f | Audit, **Deny**, Disabled |
| Conta com Managed Identity | (nova) | Cognitive Services accounts should use a managed identity | fe3fd216-4f83-4fc1-8984-2bbec80a3418 | Audit, **Deny**, Disabled |

### Por que a built-in de modelos e melhor que a minha
Minha custom era block-list por prefixo (FW-*). Apodrece: todo modelo novo escapa.
A built-in `aafe3651` e **allow-list por publisher / assetId**, com Deny. Postura default-deny.
Parametro chave: `allowedPublishers` (ex.: ["OpenAI","Microsoft"]). Tudo fora disso = negado,
incluindo Fireworks e qualquer registry model de terceiro. Mode = Microsoft.CognitiveServices.Data
(data plane do deployment de modelo).

Exemplo de params:
  allowedPublishers = ["OpenAI", "Microsoft"]
  allowedAssetIds   = []   (vazio = restringe so por publisher)

## Remediar o Foundry que JA existe (nao so negar criacao)

| Objetivo | Built-in | DefinitionId | Effect |
|---|---|---|---|
| Forcar disableLocalAuth no recurso existente | Configure Azure AI Services to disable local key access | 55eff01b-f2bd-4c32-9203-db285f709d30 | DeployIfNotExists |
| Forcar public network = Disabled no existente | Configure Cognitive Services accounts to disable public network access | 47ba1dd7-28d9-4b07-a8d5-9813bed64e0c | Modify |
| Criar Private Endpoint no existente | Configure Cognitive Services accounts with private endpoints | db630ad5-52e9-4f4d-9c44-53912fe40053 | DeployIfNotExists |
| Ligar diagnostic logs | Diagnostic logs in Azure AI services resources should be enabled | 1b4d1c4e-934c-4703-944c-27c82c06bebb | AuditIfNotExists |

DeployIfNotExists / Modify precisam de Managed Identity na assignment (`--mi-system-assigned --identity-scope`)
e role de remediacao. Rode `az policy remediation create` depois da assignment.

## MANTER custom (NAO existe built-in)

| Trava | Arquivo | Por que custom |
|---|---|---|
| **Deny SKU != Standard (mata PTU)** | policy-deny-deployment-sku.json | NAO ha built-in para restringir SKU/capacity de deployment. Esta e a trava de custo central. Alias control-plane `Microsoft.CognitiveServices/accounts/deployments/sku.name` confirmado. |
| Deny GPU compute (hub-based) | policy-deny-gpu-mlcompute.json | Especifico de Microsoft.MachineLearningServices. |
| Deny serverless / marketplace (hub) | policy-deny-serverless-marketplace.json | Idem. |

## Bonus de governanca (Audit-only, nao custo) - opcional
- Content filtering minimo por deployment / agent (varios, effect Audit/Disabled).
- CMK at rest (67121cc7-...), customer-owned storage. So se compliance pedir.

## Ordem de aplicacao recomendada
1. Built-in resource-types + locations (params em allowed-*.params.json) - maior impacto.
2. Custom SKU deny (PTU) - trava de custo central.
3. Built-in: approved models (allow-list publisher), key access disabled, restrict network, managed identity - todos Deny.
4. Hub-based: customs de GPU + serverless.
5. Remediar Foundry existente: DINE/Modify (localauth, public network, private endpoint).
6. Custom role safe-dev + quota PTU=0 + Budget/runbook.
