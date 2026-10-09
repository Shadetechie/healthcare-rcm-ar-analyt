-- 1. Executive Payer Summary: Claims, Denials, & Recovery Potential. This query tells us which insurance payers are giving us the most trouble and how much money is trapped.
SELECT 
  c.payer_type,
  COUNT(DISTINCT c.claim_id) AS total_claims,
  COUNT(DISTINCT CASE WHEN d.denial_category IS NOT NULL THEN c.claim_id END) AS total_denied_claims,
  ROUND(COUNT(DISTINCT CASE WHEN d.denial_category IS NOT NULL THEN c.claim_id END) * 100.0 / COUNT(DISTINCT c.claim_id), 2) AS denial_rate_pct,
  ROUND(SUM(d.estimated_recovery_usd), 2) AS total_estimated_recovery_usd
FROM `rcm_data.claims_main` c
LEFT JOIN `rcm_data.denial_labels` d
  ON c.claim_id = d.claim_id
GROUP BY 1
ORDER BY total_estimated_recovery_usd DESC;

-- 2. Root Cause & Appeal Potential Breakdown. This pinpoints why claims get denied and where appeals will yield the highest return.
SELECT 
  d.denial_category,
  d.denial_code_description,
  COUNT(d.claim_id) AS total_denials,
  d.appealable,
  ROUND(AVG(d.appeal_success_probability) * 100, 1) AS avg_appeal_success_pct,
  ROUND(SUM(d.estimated_recovery_usd), 2) AS total_recoverable_usd,
  d.recovery_action
FROM `rcm_data.denial_labels` d
GROUP BY 1, 2, 4, 7
ORDER BY total_recoverable_usd DESC;

-- 3. Department & Procedure Code Vulnerability Analysis. This identifies which clinical departments need training on coding or documentation.
SELECT 
  c.provider_specialty,
  c.cpt_code,
  COUNT(c.claim_id) AS total_claims,
  COUNT(d.claim_id) AS denied_claims,
  ROUND(COUNT(d.claim_id) * 100.0 / COUNT(c.claim_id), 2) AS specialty_denial_rate_pct,
  ROUND(SUM(d.estimated_recovery_usd), 2) AS total_at_risk_dollars
FROM `rcm_data.claims_main` c
LEFT JOIN `rcm_data.denial_labels` d
  ON c.claim_id = d.claim_id
GROUP BY 1, 2
HAVING COUNT(c.claim_id) >= 100
ORDER BY total_at_risk_dollars DESC
LIMIT 15;

/*
===============================================================================
Table Name: master_claims
Description:
  Combines core transactional claim records (claims_main) with denial 
  intelligence (denial_labels) and payer behavior guidelines (payer_rules) 
  into a single, consolidated flat dataset.

Key Operations:
  1. Primary Join: LEFT JOINs denial_labels on `claim_id` to attach denial 
     reasons, appeal success probabilities, and estimated recovery values.
  2. Rule Mapping: LEFT JOINs payer_rules on `cpt_code` and `payer_type` to 
     append prior authorization requirements, timely filing limits, and turnaround times.
  3. De-duplication: Uses `p.* EXCEPT (cpt_code, payer_type)` to eliminate duplicate 
     joining keys and prevent schema errors.

Business Purpose:
  Creates a unified single source of truth for downstream Accounts Receivable (AR) 
  aging, Days Sales Outstanding (DSO), and Net Collection Rate (NCR) analytics.
===============================================================================
*/
CREATE OR REPLACE TABLE `rcm_data.master_claims` AS
SELECT 
  c.*,
  d.denial_category,
  d.denial_reason_code,
  d.denial_code_description,
  d.appealable,
  d.appeal_success_probability,
  d.recovery_action,
  d.estimated_recovery_usd,
  p.* EXCEPT (cpt_code, payer_type)
FROM `rcm_data.claims_main` c
LEFT JOIN `rcm_data.denial_labels` d
  ON c.claim_id = d.claim_id
LEFT JOIN `rcm_data.payer_rules` p
  ON c.cpt_code = p.cpt_code 
  AND c.payer_type = p.payer_type;


/*
===============================================================================
Query Name: 02_rcm_ar_aging_and_velocity_analytics.sql
Description:
  Calculates Accounts Receivable (AR) Aging Buckets, At-Risk Dollar Balances,
  Average Days Open vs Payer Benchmarks, and Cumulative Running AR Balances 
  using SQL Window Functions and Date Math.
===============================================================================
*/
WITH max_dataset_date AS (
  -- Finds the newest claim date in your dataset to use as the evaluation anchor
  SELECT MAX(DATE(claim_submission_date)) AS anchor_date
  FROM `rcm_data.master_claims`
),

base_metrics AS (
  SELECT 
    c.claim_id,
    c.payer_type,
    c.provider_specialty,
    c.cpt_code,
    c.claim_submission_date,
    
    COALESCE(c.estimated_recovery_usd, 0) AS estimated_recovery_usd,
    c.avg_payment_turnaround_days,
    c.timely_filing_limit_days,
    c.appeal_success_probability,
    
    -- Date Math: Age in days relative to the dataset anchor date
    DATE_DIFF(m.anchor_date, DATE(c.claim_submission_date), DAY) AS days_open,
    
    -- AR Aging Buckets relative to anchor date
    CASE 
      WHEN DATE_DIFF(m.anchor_date, DATE(c.claim_submission_date), DAY) BETWEEN 0 AND 30 THEN '01. 0–30 days'
      WHEN DATE_DIFF(m.anchor_date, DATE(c.claim_submission_date), DAY) BETWEEN 31 AND 60 THEN '02. 31–60 days'
      WHEN DATE_DIFF(m.anchor_date, DATE(c.claim_submission_date), DAY) BETWEEN 61 AND 90 THEN '03. 61–90 days'
      WHEN DATE_DIFF(m.anchor_date, DATE(c.claim_submission_date), DAY) BETWEEN 91 AND 120 THEN '04. 91–120 days'
      ELSE '05. 120+ days'
    END AS ar_aging_bucket
  FROM `rcm_data.master_claims` c
  CROSS JOIN max_dataset_date m
)

SELECT 
  payer_type,
  provider_specialty,
  ar_aging_bucket,
  
  -- Claim Volume & Financial Totals
  COUNT(DISTINCT claim_id) AS total_claims,
  ROUND(SUM(estimated_recovery_usd), 2) AS total_at_risk_recovery_usd,
  
  -- Days Sales / Claim Age Metrics
  ROUND(AVG(days_open), 1) AS avg_days_open,
  ROUND(AVG(avg_payment_turnaround_days), 1) AS payer_benchmark_turnaround_days,
  
  -- Appeal Success Rate %
  ROUND(AVG(appeal_success_probability) * 100, 1) AS avg_appeal_success_pct,

  -- Window Function: Cumulative Running Total of At-Risk AR per Payer across Aging Buckets
  ROUND(
    SUM(SUM(estimated_recovery_usd)) OVER (
      PARTITION BY payer_type 
      ORDER BY ar_aging_bucket 
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 2
  ) AS running_total_at_risk_usd

FROM base_metrics
GROUP BY 
  payer_type,
  provider_specialty,
  ar_aging_bucket
ORDER BY 
  payer_type, 
  ar_aging_bucket;