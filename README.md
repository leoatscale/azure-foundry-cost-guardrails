# azure-foundry-cost-guardrails

Implementação de referência para conceder a um desenvolvedor um Resource Group com teto de orçamento (por exemplo, US$ 500) para testar IA no Azure AI Foundry sem risco de estourar a conta. Reúne quatro camadas de defesa, cada uma com um tempo de reação diferente: prevenção no control plane, detecção em minutos, limite de token em tempo real no gateway e contenção por orçamento.

Todos os scripts são agnósticos de ambiente. Nenhuma assinatura, locatário (tenant) ou nome de recurso fica fixo no código: você fornece tudo por parâmetro.

> **Aviso:** este repositório é um ponto de partida, e não um pacote para executar sem leitura. Antes de aplicar em qualquer ambiente real, revise e ajuste os parâmetros conforme a seção 1, e comece sempre em modo `Audit`.

---

## 1. Antes de começar: adapte ao seu ambiente

Não basta clonar e executar. Os valores abaixo precisam refletir a sua realidade antes de qualquer aplicação:

| Onde ajustar | O que mudar |
|---|---|
| Parâmetros dos scripts | `SubscriptionId`, `ResourceGroup`, `Location` e o e-mail de alerta, todos passados na linha de comando |
| `config/example.parameters.json` | Use como modelo e preencha com os seus valores (não é lido automaticamente; serve de referência) |
| `layer1-prevent/policies/params/allowed-resource-types.*.json` | Os tipos de recurso que o desenvolvedor realmente precisa criar |
| `layer1-prevent/policies/params/allowed-locations.json` | A sua região |
| `layer1-prevent/rbac/role-ai-sandbox-safe-dev.json` | O campo `AssignableScopes` traz o marcador `<SUA_SUBSCRIPTION_ID>`; o script injeta a sua assinatura automaticamente, ou edite à mão |
| `layer3-throttle/teams.json` | Copie de `teams.example.json` e defina os limites de token por time (TPM e quota) |
| Parâmetro `-Scenario` | `accountbased` ou `hubbased`, conforme o seu Foundry (veja a seção 5) |

Recomendação de adoção: comece sempre em modo `Audit` (observa e não bloqueia), revise o resultado e só então passe para `Deny`.

---

## 2. O problema

O Azure não oferece um mecanismo nativo que interrompa o consumo de um Resource Group ao atingir um valor fixo. O Budget do Cost Management gera alertas, mas não bloqueia recursos, e o dado de custo leva horas para consolidar. A interrupção automática por orçamento existe apenas em alguns tipos de assinatura (Dev/Test, MSDN e ofertas equivalentes) e atua no nível da assinatura inteira, não de um Resource Group.

Além disso, o maior risco de custo não é o consumo de token. O que mais pesa é a capacidade reservada cobrada por hora, que incide mesmo sem nenhuma requisição:

- Implantação provisionada (PTU / ProvisionedManaged) no Foundry account-based.
- Máquina virtual com GPU (famílias NC, ND, NV, NG) em um compute hub-based.
- Endpoint serverless ou de Marketplace (MaaS) que publica modelo de terceiro fora do gateway.

Por isso a estratégia não é aguardar o alerta de orçamento. É impedir que a forma de gasto mais cara seja criada, limitar o consumo de token em tempo real e ter um caminho rápido de contenção caso algo escape.

---

## 3. A solução em quatro camadas

A defesa combina camadas com tempos de reação distintos. Se uma falha, a seguinte contém.

| Camada | Função | Tempo de reação | Implementação |
|---|---|---|---|
| 1. Prevenir (control plane) | Impede a criação do que gera custo alto: PTU, GPU, serverless/marketplace, e restringe tipo de recurso e região | Imediato | `layer1-prevent/` (Azure Policy Deny + custom role) |
| 2. Detectar | Notifica por e-mail no momento em que uma implantação de IA é criada, antes de o custo aparecer no Cost Management | Minutos | `layer2-detect/` (Activity Log Alert + Action Group) |
| 3. Limitar token | Retorna HTTP 429/403 quando o consumo de token ultrapassa o teto, por time, no gateway | Tempo real | `layer3-throttle/` (API Management com `llm-token-limit`) |
| 4. Conter por orçamento | Ao atingir a faixa configurada, alerta e pode acionar uma automação de contenção | Horas | `layer4-contain/` (Budget + Action Group + Runbook) |

O detalhamento técnico está em [`docs/architecture.md`](docs/architecture.md). O guia completo com justificativas está em [`docs/Guia-Implementacao-Cost-Guardrails.pdf`](docs/Guia-Implementacao-Cost-Guardrails.pdf).

---

## 4. Escopo: o que é afetado e o que não é

As travas são aplicadas no escopo do Resource Group do sandbox. As atribuições de Azure Policy, a atribuição da custom role, o alerta de detecção e o Budget vivem no Resource Group. O restante da assinatura continua operando normalmente. Você não interrompe o ambiente inteiro.

Há duas ressalvas de escopo que merecem atenção:

1. As definições de policy personalizada e a definição da custom role são criadas no nível da assinatura, porque é onde esse tipo de objeto reside. Isso é inofensivo: uma definição só produz efeito quando atribuída a um escopo, e todas as atribuições estão no Resource Group.
2. A quota de PTU e de GPU é controlada por assinatura e região, não por Resource Group. Zerar essa quota afeta todos os Resource Groups daquela região na mesma assinatura. Portanto, se o sandbox divide a assinatura com outras cargas, não zere a quota de forma global; confie na Camada 1, que já bloqueia a criação. Se desejar poder zerar a quota com segurança, isole o sandbox em uma assinatura dedicada.

Recomendação: uma assinatura dedicada ao sandbox oferece o menor raio de impacto e permite usar todas as camadas sem efeito colateral. Ao compartilhar a assinatura, todas as camadas continuam válidas, com a única ressalva da quota.

---

## 5. Identifique o seu cenário: account-based ou hub-based

O desenho da Camada 1 depende do tipo de Foundry. Confirme antes de executar:

- **account-based** (`Microsoft.CognitiveServices/accounts`): o foco é negar a SKU provisionada (PTU) e fechar os bypasses da conta (chave local e rede pública). Use `-Scenario accountbased`.
- **hub-based** (`Microsoft.MachineLearningServices`): além do anterior, entram as travas de GPU compute e de serverless/marketplace, porque o workspace hospeda compute e endpoints próprios. Use `-Scenario hubbased`.

Como descobrir o tipo: verifique o tipo de recurso da conta do Foundry no portal ou pela CLI. Se o recurso for um Cognitive Services account, é account-based; se for um Machine Learning workspace, é hub-based.

---

## 6. Pré-requisitos

- Azure CLI autenticado: `az login`
- PowerShell 7 ou superior
- Permissão no escopo: Owner, ou a combinação Resource Policy Contributor e User Access Administrator (a Camada 3 exige também permissão para criar API Management e atribuir RBAC no Foundry)

---

## 7. Estrutura do repositório

```
azure-foundry-cost-guardrails/
  README.md
  LICENSE
  deploy-all.ps1                       # orquestra as camadas 1, 2 e 4 de uma vez
  config/
    example.parameters.json            # modelo de parâmetros (referência)
  docs/
    architecture.md                    # tese das 4 camadas
    builtins-reference.md              # custom x built-in, DefinitionIds
    topology.excalidraw                # diagrama editável
    topology.png                       # render do diagrama
    Guia-Implementacao-Cost-Guardrails.pdf
  layer1-prevent/                      # Camada 1: prevenir no control plane
    apply.ps1                          # aplica policies + custom role
    verify.ps1                         # mostra conformidade e testa um Deny
    teardown.ps1                       # rollback da camada
    policies/definitions/              # policies personalizadas (PTU, GPU, serverless)
    policies/params/                   # tipos permitidos, regiões, etc.
    rbac/role-ai-sandbox-safe-dev.json # custom role de menor privilégio
  layer2-detect/                       # Camada 2: detectar em minutos
    apply.ps1                          # Action Group + Activity Log Alert
    teardown.ps1
  layer3-throttle/                     # Camada 3: limitar token no gateway (APIM)
    deploy-layer3.ps1                  # orquestrador (passos 01 a 06)
    01-deploy-apim.ps1                 # provisiona APIM + App Insights + Log Analytics
    02-wire-foundry.ps1                # liga o APIM ao Foundry (RBAC + API)
    03-apply-token-policy.ps1          # policy de API (MI + emit-token-metric)
    04-create-products.ps1             # products por time + llm-token-limit
    05-connect-playground.ps1          # imprime a conexão do gateway
    06-observability.ps1               # logger, diagnostic e alerta de 4xx
    policies/api-policy.xml            # auth via MI + telemetria de token
    policies/product-policy.template.xml # llm-token-limit por time (429/403)
    teams.example.json                 # modelo de limites por time
  layer4-contain/                      # Camada 4: conter por orçamento
    apply-budget.ps1                   # Budget 50/75/90/100% + forecast + Action Group
    teardown.ps1
    runbook-contain.example.ps1        # runbook de contenção (exemplo, opcional)
```

---

## 8. Passo a passo

Aplique as camadas em ordem. Os exemplos usam `rg-dev-sandbox-01` e `eastus`; troque pelos seus valores. Há um atalho na seção 8.7 que aplica as camadas 1, 2 e 4 de uma vez.

### 8.1. Camada 1: prevenir (Audit, verificar, Deny)

```powershell
# Aplique em Audit (observa, não bloqueia nada).
./layer1-prevent/apply.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Location eastus -Scenario accountbased -Effect Audit

# Revise a conformidade (leva alguns minutos para popular).
./layer1-prevent/verify.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01

# Confortável com o resultado, passe para Deny.
./layer1-prevent/apply.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Location eastus -Scenario accountbased -Effect Deny
```

Para reativar a allow-list de modelos por publisher (bloqueia Fireworks e terceiros), acrescente `-EnableApprovedModels`. Ela é opcional e vem desligada por padrão; a trava de SKU/PTU já barra a forma cobrada por hora mesmo sem ela.

### 8.2. Camada 1: custom role (criar, atribuir e remover o acesso amplo do desenvolvedor)

Esta função define o perfil do desenvolvedor. A premissa é que ele tenha apenas esta função no Resource Group, e nenhuma outra. O `apply.ps1` já cria a função, injetando o `AssignableScopes` a partir da sua assinatura. Falta atribuí-la ao desenvolvedor e remover o acesso amplo:

```powershell
# 8.2a. (Opcional) criar a função manualmente, editando o marcador <SUA_SUBSCRIPTION_ID> no JSON:
az role definition create --role-definition layer1-prevent/rbac/role-ai-sandbox-safe-dev.json

# 8.2b. Atribuir a função ao desenvolvedor no escopo do Resource Group (nada acima disso):
az role assignment create --assignee <UPN_OU_OBJECTID_DO_DEV> `
  --role "AI Sandbox Safe Dev" `
  --scope /subscriptions/<SUB_ID>/resourceGroups/rg-dev-sandbox-01

# 8.2c. Remover Owner/Contributor do desenvolvedor e verificar herança:
az role assignment list --assignee <UPN_OU_OBJECTID_DO_DEV> `
  --scope /subscriptions/<SUB_ID>/resourceGroups/rg-dev-sandbox-01 --include-inherited -o table
az role assignment delete --assignee <UPN_OU_OBJECTID_DO_DEV> --role Contributor `
  --scope /subscriptions/<SUB_ID>/resourceGroups/rg-dev-sandbox-01
```

Observação importante sobre o modelo: `NotActions` não é uma negação global. Ele apenas subtrai o que esta função concede. Se o desenvolvedor também possuir Owner ou Contributor (de forma direta ou herdada da assinatura ou do grupo de gerenciamento), as restrições da função não terão efeito. Por isso, ela precisa ser a única função do desenvolvedor no Resource Group. Quando a herança vem de um escopo superior, isole o sandbox em uma assinatura separada ou utilize Deny Assignment.

### 8.3. Camada 2: detectar

```powershell
./layer2-detect/apply.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -AlertEmail voce@empresa.com -Scenario accountbased
```

Cria um Action Group (e-mail) e um Activity Log Alert que dispara no minuto em que uma implantação de IA é criada no Resource Group. No cenário `hubbased`, também cria um alerta para a criação de compute do Machine Learning (possível GPU).

### 8.4. Camada 3: limitar token no gateway (API Management)

Esta camada coloca um API Management na frente do Foundry e aplica a policy `llm-token-limit`, que corta o consumo de token em tempo real: estouro de TPM retorna HTTP 429 (com Retry-After) e estouro de quota retorna HTTP 403. O limite é definido por time, via Product do APIM.

```powershell
# 8.4a. Defina os limites por time. Copie o modelo e edite TPM/quota de cada time.
Copy-Item layer3-throttle/teams.example.json layer3-throttle/teams.json

# 8.4b. Provisione o gateway inteiro (APIM, ligação ao Foundry, policies, products, observabilidade).
./layer3-throttle/deploy-layer3.ps1 `
  -SubscriptionId <SUB_ID> `
  -ResourceGroup rg-foundry-gw-01 `
  -Location eastus2 `
  -ApimName apim-foundry-gw-01 `
  -PublisherName "Plataforma" -PublisherEmail plataforma@empresa.com `
  -FoundryName <NOME_DO_SEU_FOUNDRY> -FoundryResourceGroup <RG_DO_SEU_FOUNDRY>

# 8.4c. Pegue a conexão do gateway para apontar o Playground / os apps de um time.
./layer3-throttle/05-connect-playground.ps1 -Product team-dev
```

O APIM autentica no Foundry via Managed Identity, então o desenvolvedor nunca vê a chave do Foundry: ele usa a chave de subscription do APIM. Aponte o endpoint do Playground (ou do SDK AzureOpenAI) para a URL do gateway impressa em 8.4c. Cada passo (`01` a `06`) também pode ser executado isoladamente; veja os comentários no início de cada arquivo.

Observação honesta: por ser streaming, o Playground força uma estimativa de tokens, então calibre os limites com folga. A Camada 3 exige um API Management, que tem custo próprio; provisione-a quando o controle de token em tempo real compensar esse custo.

### 8.5. Camada 4: conter por orçamento

```powershell
./layer4-contain/apply-budget.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Amount 500 -AlertEmail voce@empresa.com
```

Cria um Budget no escopo do Resource Group com faixas de 50/75/90/100% (custo real) mais previsão (forecast), ligado a um Action Group. Para contenção automática, hospede `layer4-contain/runbook-contain.example.ps1` em um Automation Account e adicione-o como ação do tipo Automation Runbook no mesmo Action Group; ao bater 100%, o Budget aciona o runbook, que apaga as implantações de IA do Resource Group. O Budget é reativo (horas), por isso atua como última linha de defesa, e não como freio principal.

### 8.6. Reforços manuais (cenário account-based)

**Zerar a quota de PTU e de GPU (defesa em profundidade).** A policy bloqueia a forma cobrada por hora; zerar a quota garante que não exista capacidade reservável mesmo que algo escape.

```powershell
az cognitiveservices usage list --location <REGIAO> -o table   # procure linhas ProvisionedManaged
az vm list-usage --location <REGIAO> -o table                  # famílias NC/ND/NV/NG (GPU)
```

Abra uma solicitação de quota para manter PTU e GPU vCPU em zero na região do sandbox. Atenção ao escopo da seção 4: a quota é por assinatura e região; em assinatura compartilhada, não execute esta etapa de forma global.

**Fechar os bypasses do Foundry.**

```powershell
az resource update --ids <ACCOUNT_ID> --set properties.disableLocalAuth=true
az resource update --ids <ACCOUNT_ID> --set properties.publicNetworkAccess=Disabled
```

Sem chave de conta e sem rede pública, o desenvolvedor passa a usar Entra ID e, quando houver, o gateway. A custom role já nega `listKeys`, o que reforça essa postura.

### 8.7. Atalho: aplicar as camadas 1, 2 e 4 de uma vez

```powershell
./deploy-all.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Location eastus `
  -Scenario accountbased -Effect Audit -AlertEmail voce@empresa.com -BudgetAmount 500
```

O `deploy-all.ps1` aplica as camadas com escopo de Resource Group (1, 2 e 4). A Camada 3 (gateway) continua sendo executada pelo seu próprio orquestrador (8.4), por depender dos dados do Foundry e do APIM.

---

## 9. Validar que o bloqueio funciona

O `layer1-prevent/verify.ps1` aceita `-FoundryAccount` e tenta criar uma implantação PTU propositalmente. Com Deny aplicado, a operação deve falhar:

```powershell
./layer1-prevent/verify.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -FoundryAccount <NOME_DA_CONTA>
```

Saída esperada: `OK: bloqueado pela policy (esperado).`

Para a Camada 3, faça uma chamada de inferência pelo endpoint do gateway com a chave de um time e force o estouro: o consumo além do TPM retorna 429 e o estouro de quota retorna 403.

---

## 10. Rollback

Cada camada tem o seu próprio rollback. Remova na ordem inversa da aplicação:

```powershell
./layer4-contain/teardown.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01
./layer2-detect/teardown.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01
./layer1-prevent/teardown.ps1 -SubscriptionId <SUB_ID> -ResourceGroup rg-dev-sandbox-01 -Scenario accountbased
```

Para a Camada 3, remova o Resource Group do gateway ou exclua o recurso de API Management criado em 8.4. Utilize o mesmo `-Scenario` empregado na aplicação da Camada 1.

---

## Licença

MIT. Veja [`LICENSE`](LICENSE). Use por sua conta e risco; teste em ambiente não produtivo e comece em modo `Audit`.
