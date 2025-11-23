-- =============================================================================
-- pool_daily_metrics.sql
--
-- Purpose
--   Store the daily panel of spread measures, liquidity proxies, and
--   explanatory variables used in the ACD–intensity spread-forecasting
--   regressions. This table is the primary empirical dataset for the study.
--
-- Row semantics
--   One row = one (pool_id, trading_date) observation capturing Uniswap v3
--   spread levels, TVL, fee and markout ratios, pair-level return and
--   volatility, chain-level competition metrics, and the ACD-based trade
--   arrival intensity (when available).
--
-- Conventions
--   - trading_date is a UTC calendar date representing the 24-hour period
--     over which pool- and chain-level statistics are aggregated.
--   - Spread and competition variables are stored in raw units (basis points
--     or ratios) and may be log-transformed in downstream analysis code.
--   - ACD intensities are stored as non-negative per-unit rates implied by
--     the fitted ACD model for that pool and date.
--   - Data_version is an integer tag used to distinguish rebuilds of the
--     panel under different upstream filters or Dune queries.
--
-- Keys & constraints
--   - Primary key: (pool_id, trading_date).
--   - Natural keys / uniqueness:
--       - (pool_id, trading_date) uniquely identifies a daily observation for
--         a given pool.
--   - Checks:
--       - Target spread variables and the spread ratio must be non-negative.
--       - TVL, fee and markout ratios, volatility, gas price, competition
--         and internalization ratios, and ACD intensity must be non-negative
--         when present.
--
-- Relationships
--   - Foreign keys:
--       - pool_id → dex_pools.pool_id attaches each row to a canonical pool.
--       - acd_model_run_id → acd_model_runs.acd_model_run_id (nullable) links
--         an observation to the ACD fit used to compute the intensity.
--   - Downstream tables are expected to join to pool_daily_metrics via
--     pool_id (for pool-level analysis) and/or trading_date (for daily
--     cross sections).
--
-- Audit & provenance
--   - created_at records when the row was first written by the ETL pipeline.
--   - Upstream provenance (Dune query IDs, parameter settings, ACD fitting
--     notebooks) is tracked outside this table in code and documentation.
--
-- Performance
--   - The primary key index on (pool_id, trading_date) serves most time-series
--     lookups for a given pool.
--   - idx_pdm_trading_date supports daily cross-sectional queries across all
--     pools (e.g., regressions run date by date).
--
-- Change management
--   - Schema is designed to be add-only: new features should be added as
--     nullable columns with appropriate checks; existing columns and
--     constraints should not be removed.
--   - New data versions should be written either by incrementing data_version
--     or by inserting additional rows with updated metrics; destructive
--     overwrites are discouraged.
-- =============================================================================
CREATE TABLE IF NOT EXISTS pool_daily_metrics (
    -- ===========
    -- Identifiers
    -- ===========

    -- Pool id (foreign key to dex_pools)
    pool_id INTEGER NOT NULL REFERENCES dex_pools (pool_id),

    -- Date for the metrics
    trading_date DATE NOT NULL,

    -- ==================
    -- Target Variables
    -- ==================

    -- v3-Spread in basis points
    v3_spread_bps NUMERIC,

    -- Counter factual v2-spread in basis points
    cf_v2_spread_bps NUMERIC,

    -- Ratio v3 to cf_v2 spread in basis points
    v3_over_cf_v2_ratio NUMERIC,

    -- =====================
    -- Pool level regressors
    -- =====================

    -- Total value locked in USD
    tvl_usd NUMERIC,

    -- Fee revenue normalized by TVL
    fee_revenue_over_tvl NUMERIC,

    -- Markout normalized by TVL
    markout_over_tvl NUMERIC,

    -- =====================
    -- Pair level regressors
    -- =====================

    -- Log return of token pair
    pair_log_return NUMERIC,

    -- Annualized volatility of token pair
    pair_vol_annualized NUMERIC,

    -- ======================
    -- Chain level regressors
    -- ======================

    -- Gas price in usd
    gas_price_usd NUMERIC,

    -- Uniswap volume share vs all tracked DEXs for that chain-pair
    dex_competition_ratio NUMERIC,

    -- Internalization ratio using all aggregators
    internalization_ratio_all_aggs NUMERIC,

    -- ====================
    -- ACD related metadata
    -- ====================

    -- ACD model run id
    acd_model_run_id INTEGER REFERENCES acd_model_runs (acd_model_run_id),

    -- ACD intensity per minute
    acd_intensity_per_minute NUMERIC,

    -- ========
    -- Metadata
    -- ========

    -- Data version
    data_version INTEGER NOT NULL DEFAULT 1,

    -- Created at timestamp
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- ===========
    -- Constraints
    -- ===========

    -- Primary key constraint on (pool_id, trading_date)
    PRIMARY KEY (pool_id, trading_date),

    -- Target variables are non-negative
    CONSTRAINT pdm_v3_spread_bps_non_negative CHECK
    (v3_spread_bps >= 0 AND cf_v2_spread_bps >= 0 AND v3_over_cf_v2_ratio >= 0),

    -- Pool level regressors are non-negative
    CONSTRAINT pdm_pool_regressors_non_negative CHECK
    (
        tvl_usd >= 0
        AND
        fee_revenue_over_tvl >= 0
        AND
        markout_over_tvl >= 0
    ),

    -- Volatility is non-negative
    CONSTRAINT pdm_pair_regressors_non_negative CHECK
    (
        pair_vol_annualized >= 0
    ),

    -- Chain level regressors are non-negative
    CONSTRAINT pdm_chain_regressors_non_negative CHECK
    (
        gas_price_usd >= 0
        AND
        dex_competition_ratio >= 0
        AND
        internalization_ratio_all_aggs >= 0
    ),

    -- Ensure acd_intensity_per_minute is non-negative
    CONSTRAINT pdm_acd_intensity_non_negative CHECK
    (acd_intensity_per_minute >= 0)
);

-- Index on trading_date for faster queries
CREATE INDEX IF NOT EXISTS idx_pdm_trading_date
ON pool_daily_metrics (trading_date);

COMMENT ON TABLE pool_daily_metrics IS
'Daily panel of pool-level spreads,
liquidity proxies, pair- and chain-level regressors,
and ACD intensities used in spread-forecasting regressions.';

COMMENT ON COLUMN pool_daily_metrics.pool_id IS
'Foreign key to dex_pools.pool_id identifying
the DEX pool for this daily observation.';

COMMENT ON COLUMN pool_daily_metrics.trading_date IS
'UTC calendar date for which spreads,
regressors, and ACD intensity are aggregated.';

COMMENT ON COLUMN pool_daily_metrics.v3_spread_bps IS
'Realized Uniswap v3 effective spread in basis
points for the pool on trading_date.';

COMMENT ON COLUMN pool_daily_metrics.cf_v2_spread_bps IS
'Counterfactual v2-style spread in basis points
implied by the pool''s TVL on trading_date.';

COMMENT ON COLUMN pool_daily_metrics.v3_over_cf_v2_ratio IS
'Ratio of Uniswap v3 spread to the counterfactual v2 spread
(v3_spread_bps / cf_v2_spread_bps).';

COMMENT ON COLUMN pool_daily_metrics.tvl_usd IS
'End-of-day total value locked for the pool in USD on trading_date.';

COMMENT ON COLUMN pool_daily_metrics.fee_revenue_over_tvl IS
'Daily fee revenue for the pool normalized by end-of-day TVL
(a fee/APR-style liquidity proxy).';

COMMENT ON COLUMN pool_daily_metrics.markout_over_tvl IS
'Daily markout for the pool normalized by end-of-day TVL,
capturing inventory risk borne by LPs.';

COMMENT ON COLUMN pool_daily_metrics.pair_log_return IS
'Daily log return of the underlying token pair price
(typically sourced from a reference CEX).';

COMMENT ON COLUMN pool_daily_metrics.pair_vol_annualized IS
'Annualized return volatility for the token pair over trading_date,
computed from intraday returns.';

COMMENT ON COLUMN pool_daily_metrics.gas_price_usd IS
'Average gas price per transaction on the relevant chain over trading_date,
expressed in USD.';

COMMENT ON COLUMN pool_daily_metrics.dex_competition_ratio IS
'Uniswap share of total DEX trading volume for the chain–pair on trading_date
(Uniswap volume / all tracked DEX volume).';

COMMENT ON COLUMN pool_daily_metrics.internalization_ratio_all_aggs IS
'Fraction of aggregator-routed flow that is internalized by Uniswap
(all aggregators combined) for the chain–pair on trading_date.';

COMMENT ON COLUMN pool_daily_metrics.acd_model_run_id IS
'Optional foreign key to acd_model_runs.acd_model_run_id indicating
which ACD fit produced the stored intensity.';

COMMENT ON COLUMN pool_daily_metrics.acd_intensity_per_minute IS
'ACD-implied expected trade arrival intensity for the pool on trading_date,
expressed as a non-negative per-minute rate.';

COMMENT ON COLUMN pool_daily_metrics.data_version IS
'Integer version tag for the panel construction logic
(filters, Dune queries, and aggregation choices).';

COMMENT ON COLUMN pool_daily_metrics.created_at IS
'Timestamp (UTC) when this daily metrics row was created by the ETL pipeline.';
