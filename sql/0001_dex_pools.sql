-- =============================================================================
-- dex_pools.sql
--
-- Purpose
--   Store canonical metadata for all DEX liquidity pools included in the
--   ACD–intensity / spread-forecasting study. Each row defines one unique
--   on-chain pool along with its chain, token pair, and fee tier.
--
-- Row semantics
--   One row = one distinct DEX pool contract on a specific chain
--   (e.g., Uniswap v3 WETH–USDC 5 bps on Ethereum mainnet). Rows are treated
--   as slowly changing reference data; pool identities are stable once
--   inserted.
--
-- Conventions
--   - Token symbols are stored as provided by upstream metadata and compared
--     case-insensitively when enforcing distinct pairs.
--   - Token addresses are stored as text and compared case-insensitively to
--     ensure distinct contracts for token A vs. token B.
--   - Pair symbols are normalized as "<token_a_symbol>-<token_b_symbol>" with
--     a single ASCII dash separator.
--   - Sample start/end dates are calendar dates in UTC representing the
--     inclusive window for which the pool is considered in-sample.
--
-- Keys & constraints
--   - Primary key: pool_id (surrogate key used by all downstream tables).
--   - Natural keys / uniqueness:
--       - pool_address is globally unique.
--       - (chain_name, pair_symbol, fee_tier) is unique to avoid duplicate
--         logical pools on the same chain.
--   - Checks:
--       - Chain and DEX names must be non-empty after trimming.
--       - Token symbols and addresses must be non-empty and represent
--         distinct tokens.
--       - Pair symbol must match the "<token_a>-<token_b>" convention.
--       - Fee tier must be strictly positive.
--       - sample_start_date must precede sample_end_date.
--
-- Relationships
--   - Referenced by: pool_daily_metrics.pool_id and acd_model_runs.pool_id to
--     attach daily metrics and ACD model runs to a specific pool.
--   - Joins are typically performed via pool_id; (chain_name, pair_symbol,
--     fee_tier) serves as a human-readable natural key for reporting.
--
-- Audit & provenance
--   - created_at records the timestamp when the pool row was first inserted.
--   - Full upstream provenance (e.g., Dune query used to discover the pool)
--     is documented in code / notebooks rather than stored directly here.
--
-- Performance
--   - The primary key index on pool_id serves foreign-key joins from daily
--     metrics and model-run tables.
--   - The UNIQUE constraint on (chain_name, pair_symbol, fee_tier) also
--     provides a supporting index for lookups by logical pool identity.
--
-- Change management
--   - Schema is expected to be add-only: new columns should be appended with
--     sensible defaults or nullability; existing columns and constraints
--     should not be removed in place.
--   - New pools should be added as new rows; existing rows should only be
--     updated to correct metadata or adjust sample start/end dates.
-- =============================================================================
CREATE TABLE IF NOT EXISTS dex_pools (
    -- ===========
    -- Identifiers
    -- ===========

    -- Pool id (primary key)
    pool_id SERIAL PRIMARY KEY,

    -- Chain name (e.g., 'ethereum', 'arbitrum')
    chain_name TEXT NOT NULL,

    -- Dex name (e.g., 'uniswap', 'sushiswap')
    dex_name TEXT NOT NULL,

    -- Pool address
    pool_address TEXT NOT NULL UNIQUE,

    -- ============
    -- Pool Details
    -- ============

    -- Token A symbol
    token_a_symbol TEXT NOT NULL,

    -- Token B symbol
    token_b_symbol TEXT NOT NULL,

    -- Token A address
    token_a_address TEXT NOT NULL,

    -- Token B address
    token_b_address TEXT NOT NULL,

    -- Pair symbol separated by dash (e.g., 'WETH-USDC')
    pair_symbol TEXT NOT NULL,

    -- Fee tier in basis points (e.g., 30 for 0.3% fee)
    fee_tier INTEGER NOT NULL,

    -- ========
    -- Metadata
    -- ========

    -- Is this pool active in the main sample
    is_in_main_sample BOOLEAN NOT NULL DEFAULT TRUE,

    -- Sample start date
    sample_start_date DATE NOT NULL,

    -- Sample end date
    sample_end_date DATE NOT NULL,

    -- Created at timestamp
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- ===========
    -- Constraints
    -- ===========

    -- Unique constraint on (chain_name, pair_symbol, fee_tier)
    CONSTRAINT dp_unique_chain_pair_fee_tier UNIQUE
    (chain_name, pair_symbol, fee_tier),

    -- Non empty chain and dex names after trim
    CONSTRAINT dp_valid_chain_dex_names CHECK
    (
        TRIM(chain_name) <> ''
        AND
        TRIM(dex_name) <> ''
    ),

    -- Non empty and non equal token symbols after trim
    CONSTRAINT dp_valid_token_symbols CHECK
    (
        TRIM(token_a_symbol) <> ''
        AND
        TRIM(token_b_symbol) <> ''
        AND
        LOWER(TRIM(token_a_symbol)) <> LOWER(TRIM(token_b_symbol))
    ),

    -- Non empty and non equal token addresses after trim
    CONSTRAINT dp_valid_token_addresses CHECK
    (
        TRIM(token_a_address) <> ''
        AND
        TRIM(token_b_address) <> ''
        AND
        LOWER(TRIM(token_a_address)) <> LOWER(TRIM(token_b_address))
    ),

    -- Pair symbol is comprised of token A and
    -- token B symbols separated by a dash
    CONSTRAINT dp_valid_pair_symbol CHECK
    (pair_symbol = CONCAT(token_a_symbol, '-', token_b_symbol)),

    -- Fee tier is strictly positive
    CONSTRAINT dp_positive_fee_tier CHECK (fee_tier > 0),

    -- Start date is before end date if both are not null
    CONSTRAINT dp_valid_sample_dates CHECK
    (
        (sample_start_date IS NULL OR sample_end_date IS NULL)
        OR
        (sample_start_date < sample_end_date)
    )
);

COMMENT ON TABLE dex_pools IS
'Canonical metadata for DEX liquidity pools
(chain, token pair, fee tier, and sample window) used in the ACD–intensity spread-forecasting study.';

COMMENT ON COLUMN dex_pools.pool_id IS
'Surrogate primary key for the pool; 
sed as the join key by downstream tables.';

COMMENT ON COLUMN dex_pools.chain_name IS
'Logical chain identifier on which the pool contract
lives (e.g., ethereum, arbitrum, optimism).';

COMMENT ON COLUMN dex_pools.dex_name IS
'Name of the decentralized exchange
protocol hosting the pool (e.g., uniswap_v3).';

COMMENT ON COLUMN dex_pools.pool_address IS
'On-chain pool contract address; globally unique per chain and DEX.';

COMMENT ON COLUMN dex_pools.token_a_symbol IS
'Display symbol for the first token in the pair
(left-hand side of pair_symbol).';

COMMENT ON COLUMN dex_pools.token_b_symbol IS
'Display symbol for the second token in the pair
(right-hand side of pair_symbol).';

COMMENT ON COLUMN dex_pools.token_a_address IS
'Contract address of token A;
must be non-empty and distinct from token B address.';

COMMENT ON COLUMN dex_pools.token_b_address IS
'Contract address of token B;
must be non-empty and distinct from token A address.';

COMMENT ON COLUMN dex_pools.pair_symbol IS
'Normalized token pair identifier in the form
"<token_a_symbol>-<token_b_symbol>".';

COMMENT ON COLUMN dex_pools.fee_tier IS
'Pool fee tier in basis points (e.g., 5 for 0.05%%, 30 for 0.30%%).';

COMMENT ON COLUMN dex_pools.is_in_main_sample IS
'Flag indicating whether this pool is included
in the main empirical sample for regressions.';

COMMENT ON COLUMN dex_pools.sample_start_date IS
'Inclusive calendar date on which this pool first enters the in-sample window.';

COMMENT ON COLUMN dex_pools.sample_end_date IS
'Inclusive calendar date on which this pool exits the in-sample window.';

COMMENT ON COLUMN dex_pools.created_at IS
'Timestamp (UTC) when this pool metadata row was created in the database.';
