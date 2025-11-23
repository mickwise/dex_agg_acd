-- =============================================================================
-- acd_model_runs.sql
--
-- Purpose
--   Persist fitted ACD(p, q) model runs for each DEX pool, including
--   specification, estimation window, parameter vectors, and optimizer
--   diagnostics. This table provides the provenance for ACD-based intensity
--   measures used in spread-forecasting regressions.
--
-- Row semantics
--   One row = one successful ACD(p, q) fit for a given pool over a specified
--   estimation window and duration scaling. Multiple rows per pool are
--   permitted (e.g., different orders, innovation families, or sample windows).
--
-- Conventions
--   - Orders (cond_exp_duration_order, duration_order) correspond to the
--     standard ACD(p, q) notation: p = number of ψ lags, q = number of
--     duration lags.
--   - Parameters are stored in model space:
--       - est_intercept = ω
--       - est_duration_coefs = α vector (length q)
--       - est_cond_exp_duration_coefs = β vector (length p)
--       - stationarity_margin_slack = slack used to enforce ψ-stability.
--   - theta_hat holds the optimizer parameter vector in the order
--     [ω, α..., β...] and is constrained to length 1 + q + p.
--   - duration_time_units is a descriptive label for the duration scale
--     (e.g., "seconds", "milliseconds") used when constructing the ACD data.
--   - est_start_date / est_end_date define a closed estimation window on
--     calendar dates in UTC.
--
-- Keys & constraints
--   - Primary key: acd_model_run_id (surrogate).
--   - Natural keys / uniqueness:
--       - No composite natural key is enforced; multiple runs with identical
--         specs are allowed to coexist for robustness / sensitivity analysis.
--   - Checks:
--       - Orders p and q are non-negative and not both zero.
--       - innovation_type is restricted to the supported families
--         ("exponential", "weibull", "generalized gamma") with appropriate
--         shape parameters present when required.
--       - duration_time_units must be non-empty after trimming.
--       - data_length must be strictly positive.
--       - α and β arrays must have lengths consistent with q and p (or be
--         empty when the corresponding order is zero).
--       - ψ-lag array length must match p when p > 0.
--       - stationarity_margin_slack must be positive.
--       - theta_hat length must equal 1 + q + p.
--       - num_iterations, when present, must be strictly positive; final
--         gradient norm, when present, must be non-negative.
--       - est_start_date must strictly precede est_end_date.
--
-- Relationships
--   - Foreign keys:
--       - pool_id → dex_pools.pool_id attaches each model run to a canonical
--         DEX pool.
--   - Referenced by:
--       - pool_daily_metrics.acd_model_run_id, which uses this table to
--         identify the fit underlying a given daily intensity.
--   - Joins are typically performed from pool_daily_metrics to
--     acd_model_runs by acd_model_run_id or by (pool_id, est_start_date,
--     est_end_date) for window-based analyses.
--
-- Audit & provenance
--   - created_at records when the model run was persisted.
--   - Optimizer diagnostics (status, num_iterations, final_gradient_norm,
--     log_likelihood_max) provide basic provenance without storing full
--     optimizer traces.
--   - Detailed fitting configurations (e.g., line search type, tolerance
--     settings) are documented in code and notebooks rather than stored
--     column-wise here.
--
-- Performance
--   - The primary key index on acd_model_run_id serves lookups from
--     pool_daily_metrics via acd_model_run_id.
--   - idx_amr_pool_id supports joins and filters by pool_id when
--     exploring multiple runs per pool.
--   - idx_amr_pool_id_est_dates supports window-based analyses
--     filtering by pool_id and estimation dates.
--
-- Change management
--   - Schema is designed to be add-only: new diagnostics or metadata should
--     be added as nullable columns with appropriate checks; existing columns
--     and constraints should not be removed in place.
--   - New ACD fits should be appended as new rows; existing rows should be
--     treated as immutable records of historical runs.
-- =============================================================================
CREATE TABLE IF NOT EXISTS acd_model_runs (
    -- ===========
    -- Identifiers
    -- ===========

    -- Model run id (primary key)
    acd_model_run_id SERIAL PRIMARY KEY,

    -- Pool id (foreign key to acd_pools table)
    pool_id INTEGER NOT NULL REFERENCES dex_pools (pool_id),

    -- =========
    -- ACD specs
    -- =========

    -- Conditional expected duration order (p)
    cond_exp_duration_order INTEGER NOT NULL,

    -- Duration order (q)
    duration_order INTEGER NOT NULL,

    -- Innovation type
    -- (must be in 'exponential', 'weibull', 'generalized gamma')
    innovation_type TEXT NOT NULL,

    -- Weibull shape parameter (k)
    weibull_shape NUMERIC,

    -- Generalized gamma shape parameter (d)
    gen_gamma_shape_d NUMERIC,

    -- Generalized gamma shape parameter (p)
    gen_gamma_shape_p NUMERIC,

    -- ============
    -- ACD metadata
    -- ============

    -- Duration time units (e.g., 'seconds', 'milliseconds')
    duration_time_units TEXT NOT NULL,

    -- Diurnal adjustment applied (TRUE/FALSE)
    diurnal_adjusted BOOLEAN NOT NULL DEFAULT TRUE,

    -- Data length (number of durations used in estimation)
    data_length INTEGER NOT NULL,

    -- ========
    -- Run data
    -- ========

    -- Estimated intercept (omega)
    est_intercept NUMERIC NOT NULL,

    -- Estimated duration coefficients (alpha vector)
    est_duration_coefs NUMERIC [] NOT NULL,

    -- Estimated conditional expected duration coefficients (beta vector)
    est_cond_exp_duration_coefs NUMERIC [] NOT NULL,

    -- Stationarity margin slack
    stationarity_margin_slack NUMERIC NOT NULL,

    -- Estimated conditional expected duration lags (from the recursion)
    est_cond_exp_duration_lags NUMERIC [] NOT NULL,

    -- ============
    -- QMLE results
    -- ============

    -- Log likelihood maximizer (theta_hat)
    theta_hat NUMERIC [] NOT NULL,

    -- Log likelihood maximum value
    log_likelihood_max NUMERIC NOT NULL,

    -- Convergance status
    status TEXT NOT NULL,

    -- Number of iterations
    num_iterations INTEGER,

    -- Final gradient norm if available
    final_gradient_norm NUMERIC,

    -- ============
    -- Run metadata
    -- ============

    -- Estimation start date
    est_start_date DATE NOT NULL,

    -- Estimation end date
    est_end_date DATE NOT NULL,

    -- Creation timestamp
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- ===========
    -- Constraints
    -- ===========

    -- Ensure both orders are non-negative and at least one is positive
    CONSTRAINT amr_orders_valid CHECK
    (
        cond_exp_duration_order >= 0
        AND
        duration_order >= 0
        AND
        (cond_exp_duration_order + duration_order) > 0
    ),

    -- Ensure innovation type is valid
    CONSTRAINT amr_innovation_type_valid CHECK
    (
        innovation_type IN ('exponential', 'weibull', 'generalized gamma')
    ),

    -- Ensure weibull shape parameter is provided when
    -- innovation type is 'weibull' and is non-negative
    CONSTRAINT amr_weibull_shape_valid CHECK
    (
        (innovation_type <> 'weibull' AND weibull_shape IS NULL)
        OR
        (
            innovation_type = 'weibull'
            AND
            weibull_shape IS NOT NULL
            AND
            weibull_shape > 0
        )
    ),

    -- Ensure generalized gamma shape parameters are provided when
    -- innovation type is 'generalized gamma' and are non-negative
    CONSTRAINT amr_gen_gamma_shape_valid CHECK
    (
        (
            innovation_type <> 'generalized gamma'
            AND
            gen_gamma_shape_d IS NULL
            AND
            gen_gamma_shape_p IS NULL
        )
        OR
        (
            innovation_type = 'generalized gamma'
            AND
            gen_gamma_shape_d IS NOT NULL
            AND
            gen_gamma_shape_p IS NOT NULL
            AND
            gen_gamma_shape_d > 0
            AND
            gen_gamma_shape_p > 0
        )
    ),

    -- Ensure duration time units is not empty after trim
    CONSTRAINT amr_duration_time_units_valid CHECK
    (TRIM(duration_time_units) <> ''),

    -- Ensure data length is positive
    CONSTRAINT amr_data_length_positive CHECK
    (data_length > 0),

    -- Ensure estimated coefficients arrays have correct lengths
    CONSTRAINT amr_est_coefs_length_valid CHECK
    (
        (
            duration_order = 0
            OR
            array_length(est_duration_coefs, 1) = duration_order
        )
        AND
        (
            cond_exp_duration_order = 0
            OR
            (
                array_length(est_cond_exp_duration_coefs, 1)
                = cond_exp_duration_order
                AND
                array_length(est_cond_exp_duration_lags, 1)
                = cond_exp_duration_order
            )
        )
    ),

    -- Ensure stationarity margin slack is positive
    CONSTRAINT amr_stationarity_margin_slack_positive CHECK
    (stationarity_margin_slack > 0),

    -- Ensure theta_hat array has correct length
    CONSTRAINT amr_theta_hat_length_valid CHECK
    (
        array_length(theta_hat, 1)
        =
        1 + duration_order + cond_exp_duration_order
    ),

    -- Ensure num_iterations is positive if provided
    CONSTRAINT amr_num_iterations_positive CHECK
    (num_iterations > 0),

    -- Ensure final_gradient_norm is non-negative if provided
    CONSTRAINT amr_final_gradient_norm_non_negative CHECK
    (final_gradient_norm >= 0),

    -- Ensure estimation start date is before end date
    CONSTRAINT amr_valid_estimation_dates CHECK
    (est_start_date < est_end_date)
);

-- Index on pool_id for faster lookups
CREATE INDEX IF NOT EXISTS idx_amr_pool_id
ON acd_model_runs (pool_id);

-- Index on pool_id, est_start_date, est_end_date for
-- window-based analyses
CREATE INDEX IF NOT EXISTS idx_amr_pool_id_est_dates
ON acd_model_runs (pool_id, est_start_date, est_end_date);

COMMENT ON TABLE acd_model_runs IS
'Fitted ACD(p, q) model runs per DEX pool, including specification,
parameter vectors, estimation window, and optimizer diagnostics.';

COMMENT ON COLUMN acd_model_runs.acd_model_run_id IS
'Surrogate primary key for the ACD model run;
referenced by daily metrics when attaching intensities.';

COMMENT ON COLUMN acd_model_runs.pool_id IS
'Foreign key to dex_pools.pool_id identifying the DEX pool whose
trade durations were used in this ACD fit.';

COMMENT ON COLUMN acd_model_runs.cond_exp_duration_order IS
'ACD order p: number of lags of the conditional expected
duration ψ_t included in the recursion.';

COMMENT ON COLUMN acd_model_runs.duration_order IS
'ACD order q: number of lags of realized
durations x_t included in the recursion.';

COMMENT ON COLUMN acd_model_runs.innovation_type IS
'Innovation family assumed for the ACD model
(exponential, weibull, or generalized gamma).';

COMMENT ON COLUMN acd_model_runs.weibull_shape IS
'Weibull shape parameter k used when
innovation_type = ''weibull''; NULL otherwise.';

COMMENT ON COLUMN acd_model_runs.gen_gamma_shape_d IS
'Generalized-gamma shape parameter d used when
innovation_type = ''generalized gamma''; NULL otherwise.';

COMMENT ON COLUMN acd_model_runs.gen_gamma_shape_p IS
'Generalized-gamma shape parameter p used when
innovation_type = ''generalized gamma''; NULL otherwise.';

COMMENT ON COLUMN acd_model_runs.duration_time_units IS
'Descriptive label for the duration scale used when
constructing the ACD data (e.g., "seconds", "milliseconds").';

COMMENT ON COLUMN acd_model_runs.diurnal_adjusted IS
'Flag indicating whether raw durations were diurnally
adjusted before fitting the ACD model.';

COMMENT ON COLUMN acd_model_runs.data_length IS
'Number of in-sample durations used in the ACD estimation for this run.';

COMMENT ON COLUMN acd_model_runs.est_intercept IS
'Estimated intercept parameter ω of the ACD model.';

COMMENT ON COLUMN acd_model_runs.est_duration_coefs IS
'Estimated duration-lag coefficients α (length q) for
realized durations in the ACD recursion.';

COMMENT ON COLUMN acd_model_runs.est_cond_exp_duration_coefs IS
'Estimated conditional-expected-duration coefficients β
(length p) for ψ-lags in the ACD recursion.';

COMMENT ON COLUMN acd_model_runs.stationarity_margin_slack IS
'Non-negative slack term used to enforce the
ACD stationarity / ψ-stability constraint.';

COMMENT ON COLUMN acd_model_runs.est_cond_exp_duration_lags IS
'Vector of ψ-lag values implied by the recursion at the
end of the estimation sample (length p when p > 0).';

COMMENT ON COLUMN acd_model_runs.theta_hat IS
'Optimizer parameter vector at the QMLE optimum,
ordered as [ω, α..., β...] with length 1 + q + p.';

COMMENT ON COLUMN acd_model_runs.log_likelihood_max IS
'Maximum value of the (quasi-)log-likelihood
achieved at theta_hat for this run.';

COMMENT ON COLUMN acd_model_runs.status IS
'Optimizer termination status string (e.g., "converged", "max_iter_reached").';

COMMENT ON COLUMN acd_model_runs.num_iterations IS
'Number of optimizer iterations taken to reach theta_hat;
strictly positive when present.';

COMMENT ON COLUMN acd_model_runs.final_gradient_norm IS
'Norm of the gradient at theta_hat, when reported by the optimizer;
non-negative when present.';

COMMENT ON COLUMN acd_model_runs.est_start_date IS
'Inclusive calendar date of the first duration
used in the ACD estimation window.';

COMMENT ON COLUMN acd_model_runs.est_end_date IS
'Inclusive calendar date of the last duration
used in the ACD estimation window.';

COMMENT ON COLUMN acd_model_runs.created_at IS
'Timestamp (UTC) when this ACD model run record was created in the database.';
