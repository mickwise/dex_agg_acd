# DEX Liquidity & ACD Schema

PostgreSQL schema for linking:

- **DEX pools** (chain, pair, fee tier, pool metadata),
- **ACD model runs** (per-pool ACD(p, q) fits and optimizer diagnostics),
- **Daily spread panel** (Uniswap-style v3 vs. v2 spreads plus ACD intensity).

The design is intentionally **small**, **append-only**, and **regression-ready**: the database stores only
canonical pool metadata, model run summaries, and daily metrics. All heavy lifting
(trade-level durations, ACD estimation, Dune queries) happens upstream in notebooks /
Rust pipelines, and the warehouse stays lean and reproducible.

---

## 1. Design Principles

- **Clear separation of concerns**
  - `dex_pools` is the canonical registry: each row is a unique chain–DEX–pair–fee-tier pool.
  - `acd_model_runs` stores *estimation-time objects*: ACD specs, parameters, and diagnostics.
  - `pool_daily_metrics` is the **regression panel**: one row per `(pool, trading_date)`.

- **Append-only & audit-friendly**
  - Fact tables are add-only in normal operation.
  - New ACD specs / re-fits are appended as new rows in `acd_model_runs`.
  - New daily observations are appended to `pool_daily_metrics` with an explicit `data_version`.

- **Explicit invariants**
  - Pool keys are normalized: `(chain_name, pair_symbol, fee_tier)` is unique.
  - ACD orders, parameter vectors, and θ-lengths are constrained in-DB to match ACD(p, q) notation.
  - Economic quantities are constrained to be non-negative where appropriate.

- **Regression-first design**
  - `pool_daily_metrics` is the only table you need to build the fixed-effects regressions
    from *What Drives Liquidity on Decentralized Exchanges? Evidence from the Uniswap Protocol*,
    plus the new ACD intensity regressor.
  - Nullable fields allow partial metrics (e.g., missing ACD intensity) without blocking other use.

- **Performance-aware, not over-engineered**
  - B-tree indexes on primary join keys (`pool_id`, `trading_date`) and common filters.
  - No partitioning or exotic indexing until profiling shows a need.

---

## 2. Schema Map (High-Level)

```text
                 dex_pools
               (canonical pools)
                     │
         pool_id FK  │  pool_id FK
                     ▼
      ┌─────────────────────────────┐
      │       pool_daily_metrics    │
      │  daily spread & regressors  │
      └─────────────────────────────┘
                     ▲
                     │ acd_model_run_id FK (nullable)
                     │
             acd_model_runs
      (ACD(p, q) specs, parameters,
         and optimizer diagnostics)
```

### Cardinalities

- `dex_pools` → `pool_daily_metrics`: **1-to-many**  
  One pool, many daily observations.

- `dex_pools` → `acd_model_runs`: **1-to-many**  
  One pool, many ACD estimation runs (different horizons / specs).

- `acd_model_runs` → `pool_daily_metrics`: **0-or-1-to-many**  
  A daily row may or may not be linked to a specific ACD run, depending on
  whether intensity has been computed for that pool and date.

---

## 3. Table Reference

### 3.1 `dex_pools`

**Purpose**  
Canonical registry of DEX pools in the research universe. Each row captures a unique
chain–DEX–pair–fee–tier combination plus metadata about the sample window.

**Row semantics**

- One row = one logical DEX pool identified by:
  - `chain_name` (e.g., `ethereum`, `arbitrum`),
  - `dex_name` (e.g., `uniswap`),
  - `token_a_symbol` / `token_b_symbol`,
  - `fee_tier` (in basis points),
  - `pool_address` (contract address on-chain).

**Key fields**

- `pool_id` `SERIAL PRIMARY KEY` — surrogate key for joins.
- `chain_name`, `dex_name` — human-readable identifiers for chain and DEX.
- `token_a_symbol`, `token_b_symbol` — canonical token tickers for the pair.
- `token_a_address`, `token_b_address` — contract addresses for each token.
- `pair_symbol` — derived label, e.g., `WETH-USDC`.
- `fee_tier` — pool fee tier in basis points.
- `is_in_main_sample` — whether the pool participates in the main regression sample.
- `sample_start_date`, `sample_end_date` — optional sample window for that pool.
- `created_at` — insertion timestamp.

**Keys & constraints**

- PK: `pool_id`.
- Unique business key: (`chain_name`, `pair_symbol`, `fee_tier`).
- Data quality:
  - `chain_name` and `dex_name` are trimmed and non-empty.
  - Token symbols are trimmed, non-empty, and case-insensitively distinct.
  - Token addresses are trimmed, non-empty, and case-insensitively distinct.
  - `pair_symbol = token_a_symbol || '-' || token_b_symbol`.
  - `fee_tier > 0`.
  - If both `sample_start_date` and `sample_end_date` are present, then
    `sample_start_date < sample_end_date`.

**Performance & usage**

- Typical joins:
  - `pool_daily_metrics.pool_id → dex_pools.pool_id`.
  - `acd_model_runs.pool_id → dex_pools.pool_id`.
- Consider B-tree indexes on:
  - (`chain_name`, `dex_name`),
  - (`pair_symbol`, `fee_tier`),
  if you frequently filter by chain/pair or fee tier when selecting pools.

**Change management**

- Add-only for new pools; existing rows should be logically retired by toggling
  `is_in_main_sample` or adjusting `sample_start_date` / `sample_end_date`,
  not by deletion.
- New descriptive columns can be added freely as long as they’re nullable
  or have safe defaults.

---

### 3.2 `pool_daily_metrics`

**Purpose**  
Daily panel of spread outcomes and regressors at the pool–date level. This is
the main fact table feeding the fixed-effects spread regressions and ACD
intensity experiments.

**Row semantics**

- One row = one pool–day observation for a specific `pool_id` and `trading_date`.
- Target variables (v3 / counterfactual spreads) and regressors are all
  computed over that **calendar day**.

**Key fields**

- **Identifiers:**
  - `pool_id` `INTEGER NOT NULL` → `dex_pools(pool_id)`.
  - `trading_date` `DATE NOT NULL`.

- **Target variables:**
  - `v3_spread_bps` — realized v3 spread (basis points).
  - `cf_v2_spread_bps` — counterfactual v2 spread (basis points).
  - `v3_over_cf_v2_ratio` — ratio of v3 to counterfactual spread.

- **Pool-level regressors:**
  - `tvl_usd` — total value locked in USD.
  - `fee_revenue_over_tvl` — fee revenue scaled by TVL.
  - `markout_over_tvl` — markout scaled by TVL.

- **Pair-level regressors:**
  - `pair_log_return` — daily log return of the token pair.
  - `pair_vol_annualized` — annualized volatility of the pair.

- **Chain-level regressors:**
  - `gas_price_usd` — representative gas price in USD.
  - `dex_competition_ratio` — Uniswap volume share vs all tracked DEXs for that chain–pair.
  - `internalization_ratio_all_aggs` — share of volume internalized by aggregators.

- **ACD-related:**
  - `acd_model_run_id` → `acd_model_runs(acd_model_run_id)` (nullable link).
  - `acd_intensity_per_minute` — inverse expected duration implied by the ACD model.

- **Metadata:**
  - `data_version` — allows re-building with alternative definitions.
  - `created_at` — load timestamp.

**Keys & constraints**

- PK: (`pool_id`, `trading_date`) — at most one daily row per pool.
- Non-negativity checks (semantics; enforced via CHECKs in the DDL):
  - `v3_spread_bps`, `cf_v2_spread_bps`, `v3_over_cf_v2_ratio` ≥ 0 when non-NULL.
  - Pool-level regressors (`tvl_usd`, `fee_revenue_over_tvl`, `markout_over_tvl`) ≥ 0 when non-NULL.
  - Pair-level volatility (`pair_vol_annualized`) ≥ 0 when non-NULL.
  - Chain-level regressors (`gas_price_usd`, `dex_competition_ratio`,
    `internalization_ratio_all_aggs`) ≥ 0 when non-NULL.
  - `acd_intensity_per_minute` ≥ 0 when non-NULL.
- FKs:
  - `pool_id` → `dex_pools(pool_id)`.
  - `acd_model_run_id` → `acd_model_runs(acd_model_run_id)` (optional).

**Performance & usage**

- Core access patterns:
  - Pool panels: `WHERE pool_id = ? AND trading_date BETWEEN ...`.
  - Cross-sectional slices: `WHERE trading_date = ?`.
- Indexes:
  - PK (`pool_id`, `trading_date`) already covers pool-panel queries.
  - Additional B-tree index on `trading_date` (already defined as
    `idx_pdm_trading_date`) helps cross-sectional regressions and sanity checks.
- This table should remain **append-only per `data_version`** in normal operation;
  rebuilds can either bump `data_version` or truncate and reload in a controlled
  way.

**Change management**

- New regressors can be added as nullable columns with clear naming and comments.
- If definitions of existing columns change materially, prefer incrementing
  `data_version` rather than silently mutating historical values.

---

### 3.3 `acd_model_runs`

**Purpose**  
Ledger of ACD(p, q) estimation runs per pool, including model specs,
parameters, and optimizer diagnostics. Provides reproducible metadata for
linking ACD-implied intensities back to their estimation context.

**Row semantics**

- One row = one ACD estimation run for a particular `pool_id` over a defined
  sample window and with a specific model configuration
  (orders, innovation type, duration units, diurnal adjustment).

**Key fields**

- **Identifiers & relationships:**
  - `acd_model_run_id` `SERIAL PRIMARY KEY`.
  - `pool_id` `INTEGER NOT NULL` → `dex_pools(pool_id)`.

- **ACD specs:**
  - `cond_exp_duration_order` (`p`) — order of ψ lags.
  - `duration_order` (`q`) — order of duration lags.
  - `innovation_type` — `'exponential' | 'weibull' | 'generalized gamma'`.
  - `weibull_shape`, `gen_gamma_shape_d`, `gen_gamma_shape_p` — shape parameters when applicable.

- **ACD metadata:**
  - `duration_time_units` — unit used for durations (`'seconds'`, `'milliseconds'`, etc.).
  - `diurnal_adjusted` — whether diurnal adjustment was applied.
  - `data_length` — number of durations used in estimation.

- **Run data (fitted parameters):**
  - `est_intercept` — ω.
  - `est_duration_coefs` — α vector (length `q` or empty when `q = 0`).
  - `est_cond_exp_duration_coefs` — β vector (length `p` or empty when `p = 0`).
  - `stationarity_margin_slack` — ε buffer used to enforce Σα + Σβ ≤ 1 − ε.
  - `est_cond_exp_duration_lags` — ψ lags at estimation (length `p` or empty).

- **QMLE results:**
  - `theta_hat` — full parameter vector at the log-likelihood maximizer.
  - `log_likelihood_max` — maximized log-likelihood value.
  - `status` — convergence status string from the optimizer.
  - `num_iterations` — number of iterations used (nullable if unavailable).
  - `final_gradient_norm` — gradient norm at termination (nullable).

- **Run metadata:**
  - `est_start_date`, `est_end_date` — sample window used for estimation.
  - `created_at` — insertion timestamp.

**Keys & constraints**

- PK: `acd_model_run_id`.
- FK: `pool_id` → `dex_pools(pool_id)`.

- **Order validity:**
  - `cond_exp_duration_order ≥ 0`.
  - `duration_order ≥ 0`.
  - `cond_exp_duration_order + duration_order > 0`.

- **Innovation family checks:**
  - `innovation_type IN ('exponential', 'weibull', 'generalized gamma')`.
  - If `innovation_type = 'weibull'`, `weibull_shape` must be non-NULL and > 0;
    otherwise it must be NULL.
  - If `innovation_type = 'generalized gamma'`, both generalized-gamma shape
    parameters must be non-NULL and > 0; otherwise both must be NULL.

- **Metadata checks:**
  - `TRIM(duration_time_units) <> ''`.
  - `data_length > 0`.

- **Array shape checks:**
  - When `duration_order > 0`, `array_length(est_duration_coefs, 1) = duration_order`.
  - When `cond_exp_duration_order > 0`,
    `array_length(est_cond_exp_duration_coefs, 1) = cond_exp_duration_order`
    and `array_length(est_cond_exp_duration_lags, 1) = cond_exp_duration_order`.
  - `array_length(theta_hat, 1) = 1 + duration_order + cond_exp_duration_order`.

- **Non-negativity & dates:**
  - `stationarity_margin_slack ≥ 0`.
  - If present, `num_iterations > 0`.
  - If present, `final_gradient_norm ≥ 0`.
  - `est_start_date < est_end_date`.

**Performance & usage**

- Typical access patterns:
  - *Latest run per pool*:
    ```sql
    SELECT *
    FROM acd_model_runs
    WHERE pool_id = :pool_id
    ORDER BY created_at DESC
    LIMIT 1;
    ```
  - *All runs for a pool over a horizon*:
    ```sql
    SELECT *
    FROM acd_model_runs
    WHERE pool_id = :pool_id
      AND est_start_date >= :start_date;
    ```

- Useful indexes (in addition to PK):
  - B-tree on `(pool_id, created_at DESC)` for “latest run per pool”.
  - B-tree on `(pool_id, est_start_date, est_end_date)` if you do
    temporal selection by estimation window.

**Change management**

- Treat as **append-only**: new rows for new estimation windows or specs; no
  in-place mutation of past runs.
- If additional optimizer diagnostics or model variations are needed, add new
  nullable columns rather than repurposing existing ones.
