# Arquitetura: defesa por tempo de reacao

A premissa de design e simples. Como o Azure nao oferece um freio nativo de orcamento por Resource Group, a gente combina varias camadas, cada uma com um tempo de reacao diferente, da prevencao instantanea ate a contencao reativa. Se uma falha, a proxima segura.

## Por que nao basta o Budget

Budget no Cost Management e um alerta. Ele nao bloqueia recurso nenhum. Alem disso, o dado de custo demora horas para consolidar. Quem confia so no Budget descobre o estouro depois que ja aconteceu.

O hard-stop automatico que algumas pessoas lembram existe apenas em assinaturas Dev/Test, MSDN e ofertas equivalentes, e atua no nivel da assinatura, nao do RG. Para um RG de sandbox dentro de uma assinatura corporativa, ele nao se aplica.

## O que realmente estoura o custo

Nao e token. Token e consumo elastico: para de mandar request, para de cobrar. O que queima dinheiro parado e capacidade reservada por hora:

- Deployment provisionado (PTU / ProvisionedManaged) no Foundry account-based.
- VM GPU (familias NC, ND, NV, NG) num compute hub-based.
- Endpoint serverless / Marketplace (MaaS) que sobe modelo de terceiro fora do gateway.

Todos cobram 24/7 mesmo ociosos. A defesa principal e nao deixar essas formas nascerem.

## As 4 camadas

### Camada 1 - Prevenir (control plane). Reacao: instantanea

Azure Policy em modo Deny no escopo do RG, mais uma custom role de least privilege.

- Allowed resource types e allowed locations (built-in, Deny). Reduz a superficie: so os tipos e a regiao que voce listou.
- Deny de SKU provisionado (custom). Esta e a trava central. Nao existe built-in para restringir SKU/capacity de deployment. Alias de control plane usado: `Microsoft.CognitiveServices/accounts/deployments/sku.name`.
- Key access disabled, restrict network, managed identity (built-in, Deny).
- Approved models por publisher (built-in, Deny, opcional). Allow-list que mata Fireworks e qualquer registry de terceiro.
- Hub-based: deny de GPU compute e deny de serverless/marketplace (custom).
- Custom role AI Sandbox Safe Dev: deixa gerenciar deployments Standard e ler telemetria, nega RBAC, quota, capacity, billing e listKeys.

### Camada 2 - Detectar. Reacao: minutos

Activity Log Alert ligado a um Action Group. No minuto em que um deployment de IA e criado no RG, sai um email. Isso cobre o intervalo antes do custo aparecer no Cost Management. Para varredura sob demanda, use Resource Graph filtrando `microsoft.cognitiveservices` e `microsoft.machinelearningservices` no RG.

### Camada 3 - Throttle de token. Reacao: tempo real

Para quem já tem ou aceita um API Management na frente do Foundry. A policy `llm-token-limit` corta no HTTP 429/403 quando o consumo de token passa do teto configurado, por chave ou por assinatura. É o único ponto que limita o gasto de token em tempo real. Sem gateway, o controle de token fica no nível de quota da assinatura, que é grosso. Implementação completa (provisionamento do APIM, ligação ao Foundry via Managed Identity, policy por time e observabilidade) em `layer3-throttle/`.

### Camada 4 - Conter por orcamento. Reacao: horas

Budget com faixas 50/75/90/100% mais forecast, ligado a um Action Group que dispara um Runbook de contencao (por exemplo, desabilitar deployments, remover acesso, ou parar recurso). E a ultima linha porque depende do dado de custo, que e lento. Serve de rede de seguranca, nao de freio principal.

## account-based x hub-based

O desenho da Camada 1 muda conforme o tipo de Foundry:

- account-based (`Microsoft.CognitiveServices/accounts`): o foco e o deny de SKU provisionado e o fechamento de bypass da conta (disableLocalAuth, public network).
- hub-based (`Microsoft.MachineLearningServices`): alem do anterior, entram as travas de GPU compute e de serverless/marketplace, porque o workspace hospeda compute e endpoints proprios.

Confirme o tipo antes de aplicar e use o `-Scenario` correspondente.

## Defesa em profundidade: quota em zero

A policy bloqueia a criacao. Zerar a quota de PTU e de GPU vCPU na regiao do sandbox e a barreira redundante: mesmo que um assignment seja removido ou que apareca um caminho novo, sem quota nao ha capacidade reservavel. Duas barreiras independentes para a mesma forma de gasto.

## Reconciliacao com built-ins

Regra de manutencao: usar built-in com effect Deny sempre que existir, porque a Microsoft mantem e versiona. So manter custom onde nao ha built-in. Hoje isso significa manter custom apenas o deny de SKU (PTU) e, no hub-based, GPU e serverless. O mapeamento completo de custom para built-in esta em [`builtins-reference.md`](builtins-reference.md).
