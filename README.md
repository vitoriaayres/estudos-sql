# Estudos em SQL

Projetos de SQL ligados a machine learning, feitos em PostgreSQL e adaptados a partir de um guia de ideias, com as queries corrigidas onde havia erro. Os dados são sintéticos e gerados dentro do próprio banco, então não é preciso baixar nada.

## 1. Previsão de churn (`estudo_um_churn.sql`)

Constrói a tabela de features que um modelo usaria para prever quais clientes vão cancelar nos próximos 30 dias, com três tabelas: `clientes`, `transacoes` e `tickets`.

**O que o script faz:**

- cria um schema `churn` isolado, para não misturar com outros bancos de estudo, e começa com `DROP SCHEMA IF EXISTS churn CASCADE`, então pode ser executado várias vezes;
- gera 5.000 clientes e suas transações e tickets com um padrão real: cada cliente tem uma propensão oculta a cancelar, e quem tem propensão alta compra menos, abre mais tickets não resolvidos e some nos 30 dias antes de cancelar;
- remove a coluna de propensão depois de gerar os dados, porque mantê-la seria vazamento do alvo;
- monta a view `features_churn` com features calculadas só até uma **data de corte** (30/06/2026) e o alvo `cancelou_em_30d`, que marca quem cancela nos 30 dias seguintes.

**Erros do guia original que este projeto corrige:**

| Problema | Consequência | Correção |
|---|---|---|
| `LEFT JOIN` de transações e tickets no mesmo `GROUP BY` (fan-out) | `total_transacoes` e `valor_total` ficam multiplicados pelo número de tickets | cada tabela é agregada separadamente em uma CTE antes do join |
| features calculadas até `CURRENT_DATE`, sem data de corte | vazamento: para quem cancelou, "dias desde a última transação" já revela o cancelamento | parâmetro de corte; só clientes ativos no corte entram na base |

**Features da view:** plano, dias de casa, total de transações, valor total, ticket médio, transações nos últimos 30 dias e nos 30 dias anteriores (queda de atividade), dias desde a última transação, total de tickets, tickets não resolvidos e tickets nos últimos 30 dias.

## Como executar

Requer PostgreSQL (testado a partir do pgAdmin 4). Crie um banco de estudos, por exemplo `estudos_sql`, e não rode nos seus bancos de trabalho.

1. Abra o Query Tool do pgAdmin conectado ao banco de estudos.
2. Abra `estudo_um_churn.sql`, clique no editor **sem selecionar nada** e aperte F5 para rodar o arquivo inteiro.
3. Rode as três conferências do final **uma por vez**, selecionando cada uma, porque o pgAdmin só mostra o resultado do último `SELECT`:
   - contagem de linhas das três tabelas;
   - prevalência do alvo (espera-se algo em torno de 5% a 10% de cancelamentos);
   - amostra da view `features_churn`.

## Pontos de atenção

- Um único corte dá uma foto só. Em produção, repete-se por vários cortes (um por mês) e valida-se treinando nos antigos e testando nos recentes.
- `dias_desde_ultima_transacao` fica `NULL` para quem nunca comprou. Isso é informação, não erro, e deve ser tratado no modelo.
- A view serve de entrada para um modelo em R com `DBI` e `RPostgres`, no mesmo fluxo de `tidymodels` usado nos estudos em R.
