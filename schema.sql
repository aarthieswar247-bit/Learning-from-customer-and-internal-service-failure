-- Schema derived from HackathonDataset_Helix_Merged test data
-- Tables: deployments, incidents, application_logs, kb_articles

CREATE TABLE deployments (
    deployment_id       VARCHAR(30)  PRIMARY KEY,   -- e.g. DEP-2026-081
    company              VARCHAR(100) NOT NULL,      -- e.g. Helix IT Services
    application          VARCHAR(100) NOT NULL,      -- e.g. Authentication Service
    environment           VARCHAR(20)  NOT NULL,      -- Production, Staging
    version               VARCHAR(20)  NOT NULL,      -- e.g. 3.12.0
    deployment_start      TIMESTAMP    NOT NULL,
    deployment_end        TIMESTAMP    NOT NULL,
    deployment_status     VARCHAR(30)  NOT NULL,      -- Success, Completed with warnings
    deployed_by           VARCHAR(100) NOT NULL,
    release_engineer      VARCHAR(100) NOT NULL,
    deployment_summary    TEXT,
    rollback_available    BOOLEAN      NOT NULL DEFAULT FALSE
);

CREATE TABLE incidents (
    incident_number    VARCHAR(20)  PRIMARY KEY,   -- e.g. INC001001
    state              VARCHAR(20)  NOT NULL,      -- New, Open, In Progress, Closed
    company            VARCHAR(100) NOT NULL,      -- e.g. Helix IT Services
    customer_company   VARCHAR(100) NOT NULL,
    opened_at          TIMESTAMP    NOT NULL,
    caller             VARCHAR(150) NOT NULL,      -- caller email
    category           VARCHAR(50)  NOT NULL,
    subcategory        VARCHAR(50)  NOT NULL,
    priority           VARCHAR(5)   NOT NULL,      -- P1, P2, P3
    assignment_group   VARCHAR(100) NOT NULL,
    service            VARCHAR(100) NOT NULL,      -- e.g. Customer Portal
    configuration_item VARCHAR(100) NOT NULL,      -- e.g. auth-prod-cluster
    short_description  VARCHAR(255) NOT NULL,
    description         TEXT,
    affected_users      INTEGER,
    related_deployment  VARCHAR(100) NULL,          -- usually a deployment_id, but can hold
                                                     -- free text like "No recent deployment." —
                                                     -- not FK-constrained for that reason
    related_kb          VARCHAR(20)  NULL,
    resolved_at         TIMESTAMP    NULL,
    closed_at            TIMESTAMP    NULL,
    root_cause           TEXT         NULL,          -- populated once resolved/closed
    resolution_steps     TEXT         NULL           -- populated once resolved/closed
);

CREATE TABLE application_logs (
    log_id           SERIAL       PRIMARY KEY,
    incident_number  VARCHAR(20)  NOT NULL REFERENCES incidents(incident_number),
    log_timestamp    TIMESTAMP    NOT NULL,
    log_level        VARCHAR(10)  NOT NULL,      -- INFO, WARN, ERROR
    service          VARCHAR(100) NOT NULL,
    request_id       VARCHAR(30)  NOT NULL,
    correlation_id   VARCHAR(30)  NOT NULL,
    http_status      SMALLINT,
    event            VARCHAR(50),                -- e.g. Processing
    exception_type   VARCHAR(100)                -- e.g. AuthenticationException
);

CREATE TABLE kb_articles (
    kb_id             SERIAL       PRIMARY KEY,   -- surrogate: source articles have no natural ID
    title             VARCHAR(255) NOT NULL,
    company           VARCHAR(100) NOT NULL,
    service           VARCHAR(100) NOT NULL,
    problem           VARCHAR(255) NOT NULL,
    symptoms          TEXT,
    environment       VARCHAR(20),                -- Production, Staging
    cause             TEXT,
    resolution        TEXT,
    related_incident  VARCHAR(20)  NULL REFERENCES incidents(incident_number),
    keywords          VARCHAR(255),
    created_by        VARCHAR(100),
    created_date      DATE,
    root_cause        TEXT,                       -- duplicated in source alongside `cause`
    resolution_steps  TEXT                        -- duplicated in source alongside `resolution`
);

CREATE INDEX idx_incidents_related_deployment ON incidents(related_deployment);
CREATE INDEX idx_incidents_related_kb ON incidents(related_kb);
CREATE INDEX idx_kb_articles_related_incident ON kb_articles(related_incident);
CREATE INDEX idx_application_logs_incident_number ON application_logs(incident_number);
CREATE INDEX idx_application_logs_request_id ON application_logs(request_id);

-- Workflow / AI-agent tables
-- Tables: ai_analysis, sme_approval, prevention_actions, workflow_execution

CREATE TABLE ai_analysis (
    analysis_id     SERIAL       PRIMARY KEY,
    incident_id     VARCHAR(20)  NOT NULL REFERENCES incidents(incident_number),
    root_cause      TEXT,                        -- AI output
    recovery        TEXT,                        -- AI output
    fair_resolution TEXT,                        -- AI output
    prevention      TEXT,                        -- AI output
    status          VARCHAR(20)  NOT NULL DEFAULT 'Pending'
                    CHECK (status IN ('Pending', 'Approved', 'Rejected'))
);

CREATE TABLE sme_approval (
    approval_id  SERIAL       PRIMARY KEY,
    incident_id  VARCHAR(20)  NOT NULL REFERENCES incidents(incident_number),
    analysis_id  INTEGER      NOT NULL REFERENCES ai_analysis(analysis_id),
    stage        VARCHAR(20)  NOT NULL
                CHECK (stage IN ('RCA', 'Prevention')),
    decision     VARCHAR(20)  NOT NULL
                CHECK (decision IN ('Approved', 'Rejected')),
    comments     TEXT,                           -- SME comments
    approved_by  VARCHAR(100) NOT NULL            -- SME name
);

CREATE TABLE prevention_actions (
    action_id       SERIAL       PRIMARY KEY,
    incident_id     VARCHAR(20)  NOT NULL REFERENCES incidents(incident_number),
    recommendation  TEXT         NOT NULL,        -- Prevention
    owner           VARCHAR(100) NOT NULL,        -- Team responsible
    due_date        DATE,
    status          VARCHAR(20)  NOT NULL DEFAULT 'Not Started'
                    CHECK (status IN ('Not Started', 'In Progress', 'Completed')),
    verified        VARCHAR(3)   NOT NULL DEFAULT 'No'
                    CHECK (verified IN ('Yes', 'No'))
);

CREATE TABLE workflow_execution (
    execution_id     SERIAL       PRIMARY KEY,
    incident_id      VARCHAR(20)  NOT NULL REFERENCES incidents(incident_number),
    current_agent    VARCHAR(100) NOT NULL,       -- Current node
    workflow_status  VARCHAR(20)  NOT NULL
                     CHECK (workflow_status IN ('Running', 'Waiting', 'Completed')),
    started_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ai_analysis_incident_id ON ai_analysis(incident_id);
CREATE INDEX idx_sme_approval_incident_id ON sme_approval(incident_id);
CREATE INDEX idx_sme_approval_analysis_id ON sme_approval(analysis_id);
CREATE INDEX idx_prevention_actions_incident_id ON prevention_actions(incident_id);
CREATE INDEX idx_workflow_execution_incident_id ON workflow_execution(incident_id);
