-- Recomeça do zero com segurança (só afeta o schema deste estudo)
DROP SCHEMA IF EXISTS churn CASCADE;

CREATE SCHEMA churn;
SET search_path TO churn;

-- ============================================================
-- Tabelas
-- ============================================================
CREATE TABLE clientes (
    cliente_id        SERIAL PRIMARY KEY,
    nome              VARCHAR(100),
    data_cadastro     DATE NOT NULL,
    plano             VARCHAR(20) NOT NULL,      -- basico, pro, empresarial
    data_cancelamento DATE,                      -- NULL = ainda ativo
    propensao         NUMERIC                    -- só para gerar os dados, removida depois
);

CREATE TABLE transacoes (
    transacao_id   SERIAL PRIMARY KEY,
    cliente_id     INT REFERENCES churn.clientes(cliente_id),
    valor          NUMERIC(10,2),
    data_transacao DATE
);

CREATE TABLE tickets (
    ticket_id   SERIAL PRIMARY KEY,
    cliente_id  INT REFERENCES churn.clientes(cliente_id),
    tipo        VARCHAR(50),                     -- bug, duvida, reclamacao
    resolvido   BOOLEAN,
    data_ticket DATE
);

-- ============================================================
-- Dados sintéticos
-- ============================================================

-- 5.000 clientes cadastrados entre jan/2025 e jun/2026
INSERT INTO clientes (nome, data_cadastro, plano, propensao)
SELECT 'cliente_' || g,
       DATE '2025-01-01' + (random() * 540)::int,
       (ARRAY['basico','pro','empresarial'])[1 + floor(random() * 3)::int],
       random()
FROM generate_series(1, 5000) AS g;

-- Cancelamentos: concentrados entre 120 dias antes e 60 dias depois do corte (30/06/2026)
UPDATE clientes
SET data_cancelamento = GREATEST(
        data_cadastro + 30,
        DATE '2026-06-30' - 120 + (random() * 180)::int)
WHERE random() < propensao * propensao + 0.05;

-- Transações: propensão baixa compra mais; quem vai cancelar some nos últimos 30 dias
INSERT INTO transacoes (cliente_id, valor, data_transacao)
SELECT c.cliente_id,
       round((CASE c.plano WHEN 'basico' THEN 30 WHEN 'pro' THEN 80 ELSE 200 END
              * (0.8 + random() * 0.4))::numeric, 2),
       c.data_cadastro + d
FROM clientes c
CROSS JOIN generate_series(0, 540) AS d
WHERE c.data_cadastro + d <= LEAST(COALESCE(c.data_cancelamento, DATE '2026-07-30'), DATE '2026-07-30')
  AND random() < (0.01 + 0.05 * (1 - c.propensao))
                 * CASE WHEN c.data_cancelamento IS NOT NULL
                         AND c.data_cadastro + d > c.data_cancelamento - 30
                        THEN 0.2 ELSE 1 END;

-- Tickets: propensão alta reclama mais e resolve menos
INSERT INTO tickets (cliente_id, tipo, resolvido, data_ticket)
SELECT c.cliente_id,
       (ARRAY['bug','duvida','reclamacao'])[1 + floor(random() * 3)::int],
       random() > c.propensao * 0.6,
       c.data_cadastro + d
FROM clientes c
CROSS JOIN generate_series(0, 540) AS d
WHERE c.data_cadastro + d <= LEAST(COALESCE(c.data_cancelamento, DATE '2026-07-30'), DATE '2026-07-30')
  AND random() < 0.002 + 0.02 * c.propensao;

-- Remove a propensão: era a "verdade escondida", mantê-la seria vazamento
ALTER TABLE clientes DROP COLUMN propensao;

-- ============================================================
-- View de features com data de corte (30/06/2026)
-- ============================================================
CREATE VIEW features_churn AS
WITH params AS (
    SELECT DATE '2026-06-30' AS corte
),
base AS (
    SELECT c.*
    FROM clientes c CROSS JOIN params par
    WHERE c.data_cadastro <= par.corte
      AND (c.data_cancelamento IS NULL OR c.data_cancelamento > par.corte)
),
agg_transacoes AS (
    SELECT t.cliente_id,
           COUNT(*)           AS total_transacoes,
           SUM(t.valor)       AS valor_total,
           AVG(t.valor)       AS ticket_medio,
           COUNT(*) FILTER (WHERE t.data_transacao >  par.corte - 30)  AS transacoes_30d,
           COUNT(*) FILTER (WHERE t.data_transacao >  par.corte - 60
                              AND t.data_transacao <= par.corte - 30)  AS transacoes_30d_anteriores,
           MAX(t.data_transacao) AS ultima_transacao
    FROM transacoes t CROSS JOIN params par
    WHERE t.data_transacao <= par.corte
    GROUP BY t.cliente_id
),
agg_tickets AS (
    SELECT s.cliente_id,
           COUNT(*)                                        AS total_tickets,
           COUNT(*) FILTER (WHERE NOT s.resolvido)         AS tickets_nao_resolvidos,
           COUNT(*) FILTER (WHERE s.data_ticket > par.corte - 30) AS tickets_30d
    FROM tickets s CROSS JOIN params par
    WHERE s.data_ticket <= par.corte
    GROUP BY s.cliente_id
)
SELECT b.cliente_id,
       b.plano,
       par.corte - b.data_cadastro                      AS dias_de_casa,
       COALESCE(at.total_transacoes, 0)                 AS total_transacoes,
       COALESCE(at.valor_total, 0)                      AS valor_total,
       COALESCE(at.ticket_medio, 0)                     AS ticket_medio,
       COALESCE(at.transacoes_30d, 0)                   AS transacoes_30d,
       COALESCE(at.transacoes_30d_anteriores, 0)        AS transacoes_30d_anteriores,
       par.corte - at.ultima_transacao                  AS dias_desde_ultima_transacao,
       COALESCE(ak.total_tickets, 0)                    AS total_tickets,
       COALESCE(ak.tickets_nao_resolvidos, 0)           AS tickets_nao_resolvidos,
       COALESCE(ak.tickets_30d, 0)                      AS tickets_30d,
       CASE WHEN b.data_cancelamento >  par.corte
             AND b.data_cancelamento <= par.corte + 30
            THEN 1 ELSE 0 END                           AS cancelou_em_30d
FROM base b
CROSS JOIN params par
LEFT JOIN agg_transacoes at ON at.cliente_id = b.cliente_id
LEFT JOIN agg_tickets    ak ON ak.cliente_id = b.cliente_id;

-- ============================================================
-- Conferências: selecione e rode UMA POR VEZ (o pgAdmin só mostra o último resultado)
-- ============================================================

-- 1) Contagem de linhas
SELECT (SELECT COUNT(*) FROM clientes)   AS clientes,
       (SELECT COUNT(*) FROM transacoes) AS transacoes,
       (SELECT COUNT(*) FROM tickets)    AS tickets;

-- 2) Prevalência do alvo (espere algo em torno de 5% a 10% de cancelamentos)
SELECT cancelou_em_30d, COUNT(*) AS clientes,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM features_churn
GROUP BY cancelou_em_30d;

-- 3) Amostra
SELECT * FROM features_churn LIMIT 10;
