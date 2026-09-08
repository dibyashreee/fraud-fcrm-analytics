/* ============================================================
   FINANCIAL TRANSACTION MONITORING & FRAUD RISK ANALYTICS
   SQL Server script - data prep, enrichment, and fraud rules
   Dataset: PaySim (Synthetic Financial Datasets for Fraud Detection, Kaggle)
   ============================================================ */


/* ------------------------------------------------------------
   SECTION 1: SAMPLE TABLE
   PaySim's full file has 6.36M rows. We keep every fraud row
   (rare, high-value for testing rules) plus a random sample of
   300,000 legitimate rows, so the dataset stays representative
   but manageable for SQL Server + Excel.
   ------------------------------------------------------------ */

CREATE TABLE Transactions_Sample (
    txn_id INT IDENTITY(1,1) PRIMARY KEY,
    step smallint,
    type nvarchar(50),
    amount decimal(18,2),
    nameOrig nvarchar(50),
    oldbalanceOrg decimal(18,2),
    newbalanceOrig decimal(18,2),
    nameDest nvarchar(50),
    oldbalanceDest decimal(18,2),
    newbalanceDest decimal(18,2),
    isFraud bit,
    isFlaggedFraud tinyint
);

-- All known fraud transactions (8,213 rows) - amounts cast to
-- decimal(18,2) here rather than during import, since the wizard's
-- decimal parser fails on scientific-notation values in the raw CSV.
INSERT INTO Transactions_Sample (step, type, amount, nameOrig, oldbalanceOrg, newbalanceOrig, nameDest, oldbalanceDest, newbalanceDest, isFraud, isFlaggedFraud)
SELECT step, type, CAST(amount AS decimal(18,2)), nameOrig, CAST(oldbalanceOrg AS decimal(18,2)), CAST(newbalanceOrig AS decimal(18,2)), nameDest, CAST(oldbalanceDest AS decimal(18,2)), CAST(newbalanceDest AS decimal(18,2)), isFraud, isFlaggedFraud
FROM Transactions_Raw
WHERE isFraud = 1;

-- Random sample of 300,000 legitimate transactions
INSERT INTO Transactions_Sample (step, type, amount, nameOrig, oldbalanceOrg, newbalanceOrig, nameDest, oldbalanceDest, newbalanceDest, isFraud, isFlaggedFraud)
SELECT TOP 300000 step, type, CAST(amount AS decimal(18,2)), nameOrig, CAST(oldbalanceOrg AS decimal(18,2)), CAST(newbalanceOrig AS decimal(18,2)), nameDest, CAST(oldbalanceDest AS decimal(18,2)), CAST(newbalanceDest AS decimal(18,2)), isFraud, isFlaggedFraud
FROM Transactions_Raw
WHERE isFraud = 0
ORDER BY NEWID();


/* ------------------------------------------------------------
   SECTION 2: ENRICHMENT - REFERENCE TABLES
   PaySim has no geolocation or merchant-category fields, so we
   enrich it with a static Regions table and deterministic
   account/merchant mappings, enabling AML-style rules
   (impossible travel, category-based reporting) that the raw
   dataset can't otherwise support.
   ------------------------------------------------------------ */

CREATE TABLE Regions (
    region_id INT PRIMARY KEY,
    region_name nvarchar(50),
    latitude decimal(9,6),
    longitude decimal(9,6)
);

INSERT INTO Regions VALUES
(1, 'Mumbai', 19.076090, 72.877426),
(2, 'Delhi', 28.704060, 77.102493),
(3, 'Bangalore', 12.971599, 77.594566),
(4, 'Kolkata', 22.572645, 88.363892),
(5, 'Chennai', 13.082680, 80.270721),
(6, 'Pune', 18.520430, 73.856743),
(7, 'Hyderabad', 17.385044, 78.486671),
(8, 'Ahmedabad', 23.022505, 72.571365);

-- Each account gets a deterministic "home region" via CHECKSUM,
-- so the same account always maps to the same region across runs.
CREATE TABLE Accounts (
    nameOrig nvarchar(50) PRIMARY KEY,
    home_region_id INT REFERENCES Regions(region_id)
);

INSERT INTO Accounts (nameOrig, home_region_id)
SELECT DISTINCT nameOrig, (ABS(CHECKSUM(nameOrig)) % 8) + 1
FROM Transactions_Sample;

-- Merchant category is derived from the transaction type that
-- most commonly hits that destination account.
CREATE TABLE Merchants (
    nameDest nvarchar(50) PRIMARY KEY,
    merchant_category nvarchar(50)
);

INSERT INTO Merchants (nameDest, merchant_category)
SELECT nameDest, MAX(category) FROM (
    SELECT DISTINCT nameDest,
        CASE type
            WHEN 'CASH_IN' THEN 'Cash Deposit'
            WHEN 'CASH_OUT' THEN 'ATM Withdrawal'
            WHEN 'TRANSFER' THEN 'Wire Transfer'
            WHEN 'PAYMENT' THEN 'Online Payment'
            WHEN 'DEBIT' THEN 'Retail Debit'
        END AS category
    FROM Transactions_Sample
) t
GROUP BY nameDest;


/* ------------------------------------------------------------
   SECTION 3: ENRICHMENT - TIMESTAMPS & TRAVEL ANOMALIES
   PaySim's "step" column is hourly resolution only, which isn't
   granular enough for velocity or travel-time checks. We expand
   each step into a real datetime with a randomized minute/second
   offset, then inject a small percentage of "impossible travel"
   cases by deliberately assigning a different region than the
   account's home region within a short time window.
   ------------------------------------------------------------ */

ALTER TABLE Transactions_Sample ADD txn_datetime datetime2;

UPDATE Transactions_Sample
SET txn_datetime = DATEADD(SECOND, ABS(CHECKSUM(NEWID())) % 3600, DATEADD(HOUR, step, '2026-01-01'));

ALTER TABLE Transactions_Sample ADD txn_region_id INT;

-- Default: transaction happens in the account's home region
UPDATE ts
SET ts.txn_region_id = a.home_region_id
FROM Transactions_Sample ts
JOIN Accounts a ON ts.nameOrig = a.nameOrig;

-- Inject synthetic impossible-travel cases (~3% of rows):
-- force a different region so the LAG() rule in Section 5 has
-- genuine anomalies to detect.
UPDATE ts
SET ts.txn_region_id = ((a.home_region_id + 1 + ABS(CHECKSUM(NEWID())) % 7) % 8) + 1
FROM Transactions_Sample ts
JOIN Accounts a ON ts.nameOrig = a.nameOrig
WHERE ts.txn_id IN (
    SELECT TOP 3 PERCENT txn_id FROM Transactions_Sample ORDER BY NEWID()
);


/* ------------------------------------------------------------
   SECTION 4: PERFORMANCE INDEX
   Supports the velocity self-join below, which otherwise scans
   the full table per account.
   ------------------------------------------------------------ */

CREATE INDEX idx_nameOrig_datetime ON Transactions_Sample(nameOrig, txn_datetime);


/* ------------------------------------------------------------
   SECTION 5: FRAUD DETECTION RULES
   ------------------------------------------------------------ */

-- RULE 1: VELOCITY CHECK
-- Flags accounts with more than 5 transactions in any rolling
-- 10-minute window (self-join, not fixed time buckets, so a
-- burst spanning two buckets is still caught).
-- RESULT: 0 rows in this sample - most PaySim accounts (nameOrig)
-- appear only once, so there's no repeat activity to trigger a
-- burst. Rule is validated and would activate on real transaction
-- logs with genuine repeat-account activity.
SELECT 
    t1.nameOrig,
    t1.txn_id AS window_start_txn,
    t1.txn_datetime AS window_start_time,
    COUNT(t2.txn_id) AS txns_in_window
FROM Transactions_Sample t1
JOIN Transactions_Sample t2 
    ON t1.nameOrig = t2.nameOrig
    AND t2.txn_datetime BETWEEN t1.txn_datetime AND DATEADD(MINUTE, 10, t1.txn_datetime)
GROUP BY t1.nameOrig, t1.txn_id, t1.txn_datetime
HAVING COUNT(t2.txn_id) > 5
ORDER BY txns_in_window DESC;


-- RULE 2: STRUCTURING / SMURFING
-- Flags cash deposits just under the classic $10,000 reporting
-- threshold - a well-known AML red flag.
-- RESULT: 117 individual transactions.
SELECT 
    txn_id,
    nameOrig,
    amount,
    txn_datetime,
    type
FROM Transactions_Sample
WHERE type = 'CASH_IN' 
  AND amount BETWEEN 9500 AND 9999
ORDER BY amount DESC;

-- Account-level view: the real smurfing signature is the SAME
-- account making multiple near-threshold deposits, not a single
-- one-off transaction.
SELECT 
    nameOrig,
    COUNT(*) AS structuring_txn_count,
    SUM(amount) AS total_structured_amount,
    MIN(txn_datetime) AS first_occurrence,
    MAX(txn_datetime) AS last_occurrence
FROM Transactions_Sample
WHERE type = 'CASH_IN' 
  AND amount BETWEEN 9500 AND 9999
GROUP BY nameOrig
HAVING COUNT(*) >= 2
ORDER BY structuring_txn_count DESC;


-- RULE 3: OUTLIER AMOUNTS
-- Benchmarked against each TRANSACTION TYPE's peer group rather
-- than individual account history, since most accounts in this
-- dataset are single-transaction actors (a common trait of retail
-- payment logs) - per-account baselining isn't statistically
-- meaningful here. Flags transactions more than 3 standard
-- deviations above their type's average.
-- RESULT: 4,246 rows, concentrated heavily in CASH_OUT transactions.
WITH TypeStats AS (
    SELECT 
        type,
        AVG(amount) AS avg_amount,
        STDEV(amount) AS stddev_amount
    FROM Transactions_Sample
    GROUP BY type
)
SELECT 
    t.txn_id,
    t.nameOrig,
    t.type,
    t.amount,
    ts.avg_amount,
    ts.stddev_amount,
    (t.amount - ts.avg_amount) / NULLIF(ts.stddev_amount, 0) AS z_score
FROM Transactions_Sample t
JOIN TypeStats ts ON t.type = ts.type
WHERE (t.amount - ts.avg_amount) / NULLIF(ts.stddev_amount, 0) > 3
ORDER BY z_score DESC;


-- RULE 4: IMPOSSIBLE TRAVEL
-- Uses LAG() to compare each transaction's region against that
-- same account's previous transaction, flagging a region change
-- within a 60-minute window.
-- RESULT: 0 rows - same root cause as Rule 1 (LAG() needs a prior
-- transaction to compare against, and most accounts have only one).
-- Architecturally sound; would activate against data with genuine
-- repeat-account activity (e.g. real card-present transaction logs).
WITH TravelCheck AS (
    SELECT 
        txn_id,
        nameOrig,
        txn_datetime,
        txn_region_id,
        LAG(txn_datetime) OVER (PARTITION BY nameOrig ORDER BY txn_datetime) AS prev_datetime,
        LAG(txn_region_id) OVER (PARTITION BY nameOrig ORDER BY txn_datetime) AS prev_region_id
    FROM Transactions_Sample
)
SELECT 
    nameOrig,
    prev_region_id,
    txn_region_id,
    prev_datetime,
    txn_datetime,
    DATEDIFF(MINUTE, prev_datetime, txn_datetime) AS minutes_between
FROM TravelCheck
WHERE prev_region_id IS NOT NULL
  AND txn_region_id <> prev_region_id
  AND DATEDIFF(MINUTE, prev_datetime, txn_datetime) < 60
ORDER BY minutes_between ASC;


/* ------------------------------------------------------------
   SECTION 6: RISK-SCORED VIEW
   Combines the rules into a single queryable view for Excel.
   Risk tiers reflect regulatory severity, not signal
   co-occurrence: structuring is High on its own, since
   deliberate threshold evasion is itself a compliance violation
   regardless of any other signal. Outlier amounts are Medium,
   pending investigation.
   ------------------------------------------------------------ */

CREATE VIEW vw_RiskScoredTransactions AS
WITH TypeStats AS (
    SELECT type, AVG(amount) AS avg_amount, STDEV(amount) AS stddev_amount
    FROM Transactions_Sample
    GROUP BY type
)
SELECT 
    t.txn_id,
    t.nameOrig,
    t.nameDest,
    t.type,
    t.amount,
    t.txn_datetime,
    m.merchant_category,
    r.region_name,
    CASE WHEN t.type = 'CASH_IN' AND t.amount BETWEEN 9500 AND 9999 THEN 1 ELSE 0 END AS flag_structuring,
    CASE WHEN (t.amount - ts.avg_amount) / NULLIF(ts.stddev_amount, 0) > 3 THEN 1 ELSE 0 END AS flag_outlier,
    CASE 
        WHEN t.type = 'CASH_IN' AND t.amount BETWEEN 9500 AND 9999 THEN 'High'
        WHEN (t.amount - ts.avg_amount) / NULLIF(ts.stddev_amount, 0) > 3 THEN 'Medium'
        ELSE 'Low'
    END AS risk_score
FROM Transactions_Sample t
JOIN TypeStats ts ON t.type = ts.type
LEFT JOIN Merchants m ON t.nameDest = m.nameDest
LEFT JOIN Accounts a ON t.nameOrig = a.nameOrig
LEFT JOIN Regions r ON t.txn_region_id = r.region_id;


/* ------------------------------------------------------------
   SECTION 7: HEADLINE RESULTS
   These are the numbers referenced in the README and Excel
   dashboard.
   ------------------------------------------------------------ */

-- Risk-tier breakdown: High 117 / Medium 4,246 / Low ~303,850
SELECT risk_score, COUNT(*) AS txn_count, SUM(amount) AS total_flagged_value
FROM vw_RiskScoredTransactions
GROUP BY risk_score
ORDER BY 
    CASE risk_score WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END;

-- Exports used to build the Excel workbook (HighRiskAlerts, MediumRiskSample tabs)
SELECT * FROM vw_RiskScoredTransactions WHERE risk_score = 'High';
SELECT * FROM vw_RiskScoredTransactions WHERE risk_score = 'Medium';

-- Project summary stats
SELECT 
    (SELECT COUNT(*) FROM Transactions_Sample) AS total_transactions,
    (SELECT COUNT(*) FROM vw_RiskScoredTransactions WHERE risk_score = 'High') AS high_risk_count,
    (SELECT COUNT(*) FROM vw_RiskScoredTransactions WHERE risk_score = 'Medium') AS medium_risk_count,
    (SELECT SUM(amount) FROM vw_RiskScoredTransactions WHERE risk_score IN ('High','Medium')) AS total_flagged_value;
