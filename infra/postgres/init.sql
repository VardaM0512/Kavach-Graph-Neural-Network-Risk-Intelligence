-- Kavach PostgreSQL schema (structured store).
-- Companies, financial statements, users, predictions, alerts, portfolios,
-- and model versions. Relationships live in Neo4j, not here.

CREATE TABLE IF NOT EXISTS users (
    id            BIGSERIAL PRIMARY KEY,
    email         TEXT UNIQUE NOT NULL,
    name          TEXT,
    password_hash TEXT NOT NULL,
    created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS companies (
    company_id  TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    industry    TEXT,
    created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS financial_statements (
    id            BIGSERIAL PRIMARY KEY,
    company_id    TEXT REFERENCES companies(company_id),
    fiscal_year   INT NOT NULL,
    revenue       NUMERIC,
    assets        NUMERIC,
    debt          NUMERIC,
    equity        NUMERIC,
    cash          NUMERIC,
    net_profit    NUMERIC,
    ebitda        NUMERIC,
    ocf           NUMERIC,
    fcf           NUMERIC,
    UNIQUE (company_id, fiscal_year)
);

CREATE TABLE IF NOT EXISTS predictions (
    id                    BIGSERIAL PRIMARY KEY,
    company_id            TEXT REFERENCES companies(company_id),
    model_version         TEXT NOT NULL,
    distress_probability  NUMERIC NOT NULL,
    risk_band             TEXT NOT NULL,
    horizon_3m            NUMERIC,
    horizon_6m            NUMERIC,
    horizon_12m           NUMERIC,
    horizon_24m           NUMERIC,
    created_at            TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_predictions_company ON predictions(company_id);

CREATE TABLE IF NOT EXISTS alerts (
    id           BIGSERIAL PRIMARY KEY,
    company_id   TEXT REFERENCES companies(company_id),
    kind         TEXT NOT NULL,            -- early_warning | anomaly | contagion
    message      TEXT NOT NULL,
    risk         NUMERIC,
    acknowledged BOOLEAN DEFAULT FALSE,
    created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS portfolios (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT REFERENCES users(id),
    name       TEXT NOT NULL,
    holdings   JSONB NOT NULL,             -- [{company_id, weight}]
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS model_versions (
    version     TEXT PRIMARY KEY,
    algorithm   TEXT,                       -- gcn | graphsage | gat | xgboost
    pr_auc      NUMERIC,
    roc_auc     NUMERIC,
    trained_at  TIMESTAMPTZ DEFAULT now()
);
