# Superstore Analytics: Complete End-to-End Technical Guide
### From Flat CSV File → Production-Grade Star Schema

This document captures **every single step, SQL command, config file, and design decision** made while building this project. Use this to explain the full pipeline to your team.

---

## Phase 1: Snowflake Infrastructure — Database & Schema Creation

Before writing a single line of dbt code, we set up the entire Snowflake infrastructure. We used a **two-database architecture** to separate raw ingested data from transformed analytics data.

**Role used:** `ACCOUNTADMIN` (we fixed the ownership issue this caused later in Phase 5).

```sql
-- ============================================
-- PRODUCTION DATABASES
-- ============================================

-- Bronze Layer: Raw data lands here, untouched
CREATE DATABASE IF NOT EXISTS SUPERSTORE_RAW
  DATA_RETENTION_TIME_IN_DAYS = 7
  COMMENT = 'Bronze layer: raw ingested data from source systems';

-- Silver + Gold Layers: dbt reads from RAW and writes all transformations here
CREATE DATABASE IF NOT EXISTS SUPERSTORE_ANALYTICS
  DATA_RETENTION_TIME_IN_DAYS = 30
  COMMENT = 'Silver+Gold layers: dbt-managed transformations and marts';
```

**Why two databases instead of one?**
In enterprise environments, the raw data team and the analytics team are often completely different groups. By splitting into two databases, we can give the ingestion team full control over `SUPERSTORE_RAW` without them ever touching `SUPERSTORE_ANALYTICS`, and vice versa.

### Schema Creation

Inside each database, we created purpose-specific schemas. Each schema maps to a layer of the Medallion Architecture:

```sql
-- ============================================
-- RAW SCHEMAS (One per source system — industry pattern)
-- ============================================
CREATE SCHEMA IF NOT EXISTS SUPERSTORE_RAW.SUPERSTORE
  COMMENT = 'Raw data from Superstore retail system';

-- ============================================
-- ANALYTICS SCHEMAS (dbt manages these, but we pre-create for RBAC grants)
-- ============================================
CREATE SCHEMA IF NOT EXISTS SUPERSTORE_ANALYTICS.STAGING
  COMMENT = 'Staging views — 1:1 with source, type-cast and renamed';

CREATE SCHEMA IF NOT EXISTS SUPERSTORE_ANALYTICS.INTERMEDIATE
  COMMENT = 'Intermediate models — business logic, joins, aggregations';

CREATE SCHEMA IF NOT EXISTS SUPERSTORE_ANALYTICS.MARTS
  COMMENT = 'Gold layer — star schema dimensions and facts';

CREATE SCHEMA IF NOT EXISTS SUPERSTORE_ANALYTICS.SNAPSHOTS
  COMMENT = 'SCD Type 2 snapshot tables managed by dbt';

CREATE SCHEMA IF NOT EXISTS SUPERSTORE_ANALYTICS.AUDIT
  COMMENT = 'Run logs, freshness checks, model execution metrics';
```

**Why pre-create schemas if dbt creates them automatically?**
Because we need to attach RBAC grants (permissions) to these schemas *before* dbt runs. If dbt creates them on the fly, the Analyst role won't have access until someone manually grants it.

---

## Phase 2: Snowflake Warehouses (Compute)

We created **two separate warehouses** to isolate workloads. This is a critical cost-control and performance pattern.

```sql
-- ============================================
-- COMPUTE WAREHOUSES
-- ============================================

-- Warehouse for dbt automated runs
CREATE WAREHOUSE IF NOT EXISTS DBT_WH
  WITH WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60          -- Suspends after 60 seconds of idle (programmatic runs are fast)
  AUTO_RESUME = TRUE         -- Wakes up automatically when a query hits it
  INITIALLY_SUSPENDED = TRUE -- Don't start billing until the first query
  COMMENT = 'Warehouse for dbt automated runs and transformations';

-- Warehouse for BI tools and human analysts
CREATE WAREHOUSE IF NOT EXISTS ANALYST_WH
  WITH WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 120         -- 120 seconds (humans take coffee breaks between queries)
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Warehouse for BI tools and ad-hoc analyst queries';
```

**Why two warehouses?**
If a BI analyst runs a massive `SELECT *` query, it would compete with dbt's transformation jobs on a shared warehouse, slowing both down. By isolating compute, dbt never fights with analysts for resources.

**Why different AUTO_SUSPEND values?**
- `DBT_WH` at 60s: dbt runs are programmatic and fast. There's no human thinking time between queries. Suspend quickly to save money.
- `ANALYST_WH` at 120s: Humans take 30–60 seconds to look at results before writing the next query. If we suspend too fast, they'll waste time waiting for the warehouse to resume.

---

## Phase 3: RBAC — Role-Based Access Control

This is the security backbone of the entire project. We created a strict role hierarchy following the **Principle of Least Privilege**: every user and service account only gets the minimum permissions they need.

### Role Hierarchy Diagram
```
         ACCOUNTADMIN
         /          \
   SECURITYADMIN   SYSADMIN
                      |
                   DBT_ROLE        ← dbt service account uses this
                      |
                 ANALYST_ROLE      ← BI tools and analysts use this
```

### Creating Roles
```sql
-- ============================================
-- STEP 1: CREATE ROLES
-- ============================================
USE ROLE USERADMIN;  -- USERADMIN is specifically designed for creating users and roles

CREATE ROLE IF NOT EXISTS DBT_ROLE
  COMMENT = 'Used by dbt for automated transformations';

CREATE ROLE IF NOT EXISTS ANALYST_ROLE
  COMMENT = 'Used by BI tools and analysts for querying';
```

### Building the Role Hierarchy
```sql
-- ============================================
-- STEP 2: BUILD ROLE HIERARCHY
-- ============================================
USE ROLE SECURITYADMIN;  -- SECURITYADMIN manages "who has access to what"

-- ANALYST_ROLE rolls up into DBT_ROLE (so dbt can see everything analysts can see)
GRANT ROLE ANALYST_ROLE TO ROLE DBT_ROLE;

-- DBT_ROLE rolls up into SYSADMIN (so DBAs can manage all objects)
GRANT ROLE DBT_ROLE TO ROLE SYSADMIN;
```

**Why does DBT_ROLE inherit ANALYST_ROLE?**
Because dbt needs to read from the same tables that analysts query. Instead of granting the same permissions twice, we let the hierarchy handle it.

**Why does SYSADMIN sit above DBT_ROLE?**
SYSADMIN is the "database administrator" role. It needs visibility into every object (tables, views, schemas) to manage them. But it does NOT manage security — that's SECURITYADMIN's job. This is called **Separation of Duties**.

### Granting Permissions
```sql
-- ============================================
-- STEP 3: GRANT COMPUTE (WAREHOUSE) ACCESS
-- ============================================
GRANT USAGE ON WAREHOUSE DBT_WH TO ROLE DBT_ROLE;
GRANT USAGE ON WAREHOUSE ANALYST_WH TO ROLE ANALYST_ROLE;

-- ============================================
-- STEP 4: GRANT STORAGE ACCESS TO DBT_ROLE
-- ============================================

-- dbt needs to READ from the raw database
GRANT USAGE ON DATABASE SUPERSTORE_RAW TO ROLE DBT_ROLE;
GRANT USAGE ON SCHEMA SUPERSTORE_RAW.SUPERSTORE TO ROLE DBT_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA SUPERSTORE_RAW.SUPERSTORE TO ROLE DBT_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SUPERSTORE_RAW.SUPERSTORE TO ROLE DBT_ROLE;
-- ^ FUTURE TABLES: If the ingestion team adds new raw tables tomorrow, dbt can read them
--   automatically without anyone running manual grants again.

-- dbt needs to READ and WRITE to the analytics database
GRANT USAGE, CREATE SCHEMA ON DATABASE SUPERSTORE_ANALYTICS TO ROLE DBT_ROLE;
GRANT ALL PRIVILEGES ON ALL SCHEMAS IN DATABASE SUPERSTORE_ANALYTICS TO ROLE DBT_ROLE;
GRANT ALL PRIVILEGES ON FUTURE SCHEMAS IN DATABASE SUPERSTORE_ANALYTICS TO ROLE DBT_ROLE;
```

### Creating the dbt Service Account
```sql
-- ============================================
-- STEP 5: CREATE A SERVICE ACCOUNT USER FOR dbt
-- ============================================
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS SVC_DBT_USER
  PASSWORD = '<secure_password>'
  DEFAULT_ROLE = DBT_ROLE
  DEFAULT_WAREHOUSE = DBT_WH
  MUST_CHANGE_PASSWORD = FALSE
  COMMENT = 'Service account for dbt';

-- ============================================
-- STEP 6: ASSIGN ROLES TO USERS
-- ============================================
USE ROLE SECURITYADMIN;

GRANT ROLE DBT_ROLE TO USER SVC_DBT_USER;
GRANT ROLE DBT_ROLE TO USER CURRENT_USER();      -- So you can test dbt locally
GRANT ROLE ANALYST_ROLE TO USER CURRENT_USER();   -- So you can query marts like an analyst
```

**Why a service account (`SVC_DBT_USER`) instead of your personal account?**
In production, dbt runs on a schedule (via Airflow, dbt Cloud, etc.). If you used your personal account and left the company, the entire pipeline would break. A service account is permanent and not tied to any individual.

---

## Phase 4: Resource Monitors (Cost Control)

Resource Monitors are Snowflake's built-in billing alarm system. We set one up to prevent runaway costs.

```sql
USE ROLE ACCOUNTADMIN;  -- Only ACCOUNTADMIN can create Resource Monitors

CREATE OR REPLACE RESOURCE MONITOR SUPERSTORE_RM
  WITH CREDIT_QUOTA = 50          -- Maximum 50 credits per month
  FREQUENCY = MONTHLY             -- Resets every month
  START_TIMESTAMP = IMMEDIATELY   -- Start tracking right now
  TRIGGERS
    ON 50 PERCENT DO NOTIFY                -- At 25 credits: send email alert
    ON 75 PERCENT DO NOTIFY                -- At 37.5 credits: send another alert
    ON 100 PERCENT DO SUSPEND              -- At 50 credits: stop new queries gracefully
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;   -- At 55 credits: kill running queries immediately

-- Attach the monitor to BOTH warehouses
ALTER WAREHOUSE DBT_WH SET RESOURCE_MONITOR = SUPERSTORE_RM;
ALTER WAREHOUSE ANALYST_WH SET RESOURCE_MONITOR = SUPERSTORE_RM;

USE ROLE SYSADMIN;  -- Switch back to a safer role
```

**Why `SUSPEND` at 100% and `SUSPEND_IMMEDIATE` at 110%?**
`SUSPEND` lets currently running queries finish, but blocks new ones. But if a rogue query runs for hours and keeps consuming credits past 100%, `SUSPEND_IMMEDIATE` at 110% forcefully kills it to protect your wallet.

---

## Phase 5: The Ownership Fix

We hit a real-world problem here. Because we created the databases using `ACCOUNTADMIN`, the `DBT_ROLE` (which sits under `SYSADMIN`) couldn't create objects inside them. We had to transfer ownership:

```sql
USE ROLE ACCOUNTADMIN;

GRANT OWNERSHIP ON DATABASE SUPERSTORE_RAW TO ROLE SYSADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE SUPERSTORE_ANALYTICS TO ROLE SYSADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE SUPERSTORE_RAW TO ROLE SYSADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE SUPERSTORE_ANALYTICS TO ROLE SYSADMIN COPY CURRENT GRANTS;
```

**Lesson learned:** Always create databases and schemas using `SYSADMIN`, not `ACCOUNTADMIN`. This avoids the ownership transfer step entirely.

---

## Phase 6: Raw Data Ingestion (Loading the CSV)

### Step 1: Create the File Format
We defined exactly how Snowflake should read our CSV file:

```sql
USE ROLE SYSADMIN;
USE DATABASE SUPERSTORE_RAW;
USE SCHEMA SUPERSTORE;

CREATE OR REPLACE FILE FORMAT SUPERSTORE_CSV_FORMAT
  TYPE = CSV
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1                              -- First row is column headers
  NULL_IF = ('NULL', 'null', '')               -- Treat these strings as actual NULLs
  EMPTY_FIELD_AS_NULL = TRUE                   -- Empty cells become NULL
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'           -- Handle commas inside quoted fields
  ENCODING = 'UTF8';                           -- Handle special characters
```

### Step 2: Create the Internal Stage
A Stage is a temporary landing zone where we upload the CSV before loading it into the table:

```sql
CREATE OR REPLACE STAGE SUPERSTORE_STAGE
  FILE_FORMAT = SUPERSTORE_CSV_FORMAT
  COMMENT = 'Internal stage for Superstore raw data';
```

**How we uploaded the file:** We used the Snowsight UI (Data → Databases → Stages → + Files) to drag-and-drop the CSV into `SUPERSTORE_STAGE`.

### Step 3: Create the Raw Table (ALL VARCHAR!)
This is the critical ELT design decision. Every single column is `VARCHAR`, even columns that are obviously numbers or dates:

```sql
CREATE OR REPLACE TABLE RAW_ORDERS (
    row_id          VARCHAR,
    order_id        VARCHAR,
    order_date      VARCHAR,   -- Stored as text! We cast it in dbt staging
    ship_date       VARCHAR,   -- Stored as text! We cast it in dbt staging
    ship_mode       VARCHAR,
    customer_id     VARCHAR,
    customer_name   VARCHAR,
    segment         VARCHAR,
    country         VARCHAR,
    city            VARCHAR,
    state           VARCHAR,
    postal_code     VARCHAR,
    region          VARCHAR,
    product_id      VARCHAR,
    category        VARCHAR,
    sub_category    VARCHAR,
    product_name    VARCHAR,
    sales           VARCHAR,   -- Stored as text! We cast it in dbt staging
    quantity        VARCHAR,   -- Stored as text! We cast it in dbt staging
    discount        VARCHAR,   -- Stored as text! We cast it in dbt staging
    profit          VARCHAR,   -- Stored as text! We cast it in dbt staging
    _loaded_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()  -- Metadata: when was this row ingested?
);
```

**Why ALL VARCHAR?**
If the source system sends `"N/A"` in the `sales` column, a `FLOAT` column would crash the entire `COPY INTO` command and zero rows would load. By using `VARCHAR`, the load always succeeds. We handle the type conversion safely in dbt's staging layer using `CAST()`.

**Why `_loaded_at`?**
This is a metadata column. It records the exact timestamp each row was ingested. dbt uses this for **source freshness** checks to alert us if data stops arriving.

### Step 4: Load the Data
```sql
USE WAREHOUSE DBT_WH;  -- IMPORTANT: We must activate a warehouse to run compute!

COPY INTO SUPERSTORE_RAW.SUPERSTORE.RAW_ORDERS (
    row_id, order_id, order_date, ship_date, ship_mode,
    customer_id, customer_name, segment, country, city,
    state, postal_code, region, product_id, category,
    sub_category, product_name, sales, quantity, discount, profit
)
FROM @SUPERSTORE_STAGE
FILE_FORMAT = SUPERSTORE_CSV_FORMAT
ON_ERROR = 'CONTINUE';   -- If one row is corrupt, skip it and load the rest
```

**Result:** ~9,994 rows loaded successfully into `SUPERSTORE_RAW.SUPERSTORE.RAW_ORDERS`.

---

## Phase 7: dbt Project Initialization

### Step 1: Create the Project
```powershell
cd ~/Desktop
dbt init --project-name superstore_analytics
```

dbt prompted us for connection details:
| Setting | Value |
|---|---|
| Database | Snowflake |
| Account | EJZUHOV-IXB49852 |
| User | SVC_DBT_USER |
| Role | DBT_ROLE |
| Warehouse | DBT_WH |
| Database | SUPERSTORE_ANALYTICS |
| Schema | STAGING |
| Threads | 4 |

These were saved to `~/.dbt/profiles.yml`.

### Step 2: Install External Packages
We created `packages.yml` at the project root:
```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: 1.1.1
  - package: calogica/dbt_expectations
    version: 0.10.1
```

Then installed them:
```bash
dbt deps
```

**Why `dbt_utils`?**
It gives us `generate_surrogate_key()` (cross-database compatible hashing), `date_spine()`, `pivot()`, and dozens of other production macros so we don't reinvent the wheel.

### Step 3: Configure `dbt_project.yml`
This is the "brain" of the project. It controls how every model is materialized:

```yaml
name: 'superstore_analytics'
version: '1.0.0'
config-version: 2
profile: 'superstore_analytics'

models:
  superstore_analytics:
    +tags: ['superstore']
    staging:
      +materialized: view       # Staging = lightweight views (not queried by BI)
      +schema: staging
    intermediate:
      +materialized: ephemeral  # Intermediate = exists only inside other queries (no table/view created)
    marts:
      +materialized: table      # Marts = physical tables (BI tools query these heavily)
      +schema: marts
      core:
        +tags: ['core']
      sales:
        +tags: ['reporting', 'sales']

seeds:
  superstore_analytics:
    +schema: staging

snapshots:
  superstore_analytics:
    +target_schema: snapshots

tests:
  +severity: warn

vars:
  date_spine_start: '2014-01-01'
  date_spine_end: '2018-12-31'
  incremental_lookback_days: 3

clean-targets:
  - "target"
  - "dbt_packages"
```

**Key decisions:**
- `staging: view` → Saves storage. Staging is just a pass-through for casting/renaming.
- `intermediate: ephemeral` → These CTEs exist only inside the final query. Zero storage cost.
- `marts: table` → BI tools need fast physical tables to query.
- `tests: severity: warn` → Tests log warnings instead of failing the build (configurable per-test).

### Step 4: The Custom Schema Macro
By default, dbt concatenates your target schema with the custom schema (e.g., `STAGING_staging`). We overrode this behavior:

**File:** `macros/generate_schema_name.sql`

This macro strips the prefix so dbt creates clean schema names:
- `STAGING` instead of `STAGING_staging`
- `MARTS` instead of `STAGING_marts`

### Step 5: Git Initialization
```powershell
git init
git add .
git commit -m "chore: initial dbt project setup and configuration"
```

Added `.venv/` to `.gitignore`.

---

## Phase 8: The Staging Model (Silver Layer)

### Source Definition (`models/staging/src_superstore.yml`)
We mapped the raw table so dbt knows where to find it:
```yaml
sources:
  - name: superstore
    database: superstore_raw       # Points to the RAW database
    schema: superstore             # Points to the RAW schema
    tables:
      - name: raw_orders
```

### The Staging SQL (`models/staging/stg_superstore__orders.sql`)

**Step 1: Determine the Grain.**
We ran the "Duplicate Hunter" query:
```sql
SELECT order_id, COUNT(*) FROM raw_orders GROUP BY order_id HAVING COUNT(*) > 1;
```
Result: `order_id` was NOT unique. Multiple products exist per order. The true grain is "one row per product per order."

**Step 2: Generate the Primary Key.**
We hashed `order_id` + `product_id` to create a deterministic Surrogate Key:

```sql
with raw_data as (
    select * from {{ source('superstore', 'raw_orders') }}
)

select
    -- PRIMARY KEY: Hash of order_id + product_id = unique row identifier
    {{ dbt_utils.generate_surrogate_key(['order_id', 'product_id']) }} as order_item_id,

    -- IDs (kept as VARCHAR)
    order_id,
    customer_id,
    product_id,

    -- DATES: Cast from VARCHAR strings to proper DATE type
    cast(order_date as date) as order_date,
    cast(ship_date as date) as ship_date,

    -- DIMENSIONS
    ship_mode,
    customer_name,
    segment,
    country,
    city,
    state,
    postal_code,
    region,
    category,
    sub_category,
    product_name,

    -- METRICS: Cast from VARCHAR strings to proper numeric types
    cast(sales as float) as sales,
    cast(quantity as integer) as quantity,
    cast(discount as float) as discount,
    cast(profit as float) as profit

from raw_data
```

### Staging Tests (`models/staging/stg_superstore.yml`)
```yaml
version: 2

models:
  - name: stg_superstore__orders
    description: "Cleaned, type-cast staging model. One row per product per order."
    columns:
      - name: order_item_id
        description: "Surrogate primary key (MD5 hash of order_id + product_id)."
        tests:
          - unique
          - not_null
      - name: order_id
        tests:
          - not_null
      - name: product_id
        tests:
          - not_null
```

**Ran:** `dbt run --select stg_superstore__orders` → Created a VIEW in `SUPERSTORE_ANALYTICS.STAGING`.
**Ran:** `dbt test --select stg_superstore__orders` → All tests passed.

---

## Phase 9: The History Engine — dbt Snapshots (SCD Type 2)

### Customer Snapshot (`snapshots/snp_customers.sql`)
```sql
{% snapshot snp_customers %}

{{
    config(
      target_schema='snapshots',
      unique_key='customer_id',       -- The anchor: "WHO are we tracking?"
      strategy='check',               -- No updated_at column, so check for value changes
      check_cols=['customer_name', 'segment']  -- ONLY these attributes trigger a new version
    )
}}

select distinct
    customer_id,
    customer_name,
    segment
from {{ ref('stg_superstore__orders') }}

{% endsnapshot %}
```

**Why only `customer_name` and `segment` in `check_cols`?**
We do NOT include `city`, `state`, or `country` because those belong to `dim_locations`. If a customer moves cities, that's a Location change, not a Customer change. Our Star Schema already handles it via a different `location_sk` in the Fact table.

**What dbt generates automatically (the 4 secret columns):**
| Column | Purpose |
|---|---|
| `dbt_scd_id` | Time-aware Surrogate Key (hash of `customer_id` + timestamp) |
| `dbt_updated_at` | When dbt last checked this record |
| `dbt_valid_from` | When this version of the customer started existing |
| `dbt_valid_to` | When this version expired (`NULL` = currently active) |

**How "closing" a record works:**
1. **Before change:** Customer #1 is "Consumer". `dbt_valid_to = NULL` (active).
2. **After change:** dbt runs `UPDATE` on the old row, setting `dbt_valid_to = 2024-01-02`. Then it `INSERT`s a new row with segment = "Corporate" and `dbt_valid_to = NULL`.

### Product Snapshot (`snapshots/snp_products.sql`)
```sql
{% snapshot snp_products %}

{{
    config(
      target_schema='snapshots',
      unique_key='product_id',
      strategy='check',
      check_cols=['category', 'sub_category', 'product_name']
    )
}}

select distinct
    product_id,
    category,
    sub_category,
    product_name
from {{ ref('stg_superstore__orders') }}

{% endsnapshot %}
```

**Ran:** `dbt snapshot` → Created snapshot tables in `SUPERSTORE_ANALYTICS.SNAPSHOTS`.

---

## Phase 10: The Dimension Tables (Gold Layer)

### Customer Dimension (`models/marts/core/dim_customers.sql`)
```sql
{{ config(materialized='view') }}  -- Override: View instead of table to avoid duplicating snapshot data

with snapshot as (
    select * from {{ ref('snp_customers') }}
),

customers as (
    select
        dbt_scd_id as customer_sk,   -- Rename dbt's system column to Kimball standard
        customer_id,
        customer_name,
        segment,
        dbt_valid_from,              -- Expose for Point-in-Time joins in the Fact table
        dbt_valid_to                 -- Expose for Point-in-Time joins in the Fact table
    from snapshot
)

select * from customers
```

**Why `materialized='view'`?**
The global config says `marts: table`. But since `dim_customers` just renames columns from the snapshot, storing it as a physical table would be a complete waste of storage. We override the global config to make it a lightweight view.

### Product Dimension (`models/marts/core/dim_products.sql`)
```sql
{{ config(materialized='view') }}

with snapshot as (
    select * from {{ ref('snp_products') }}
),

products as (
    select
        dbt_scd_id as product_sk,
        product_id,
        category,
        sub_category,
        product_name,
        dbt_valid_from,
        dbt_valid_to
    from snapshot
)

select * from products
```

### Location Dimension (`models/marts/core/dim_locations.sql`)
```sql
-- NO snapshot needed! Locations don't change over time.
-- Bangalore doesn't become Hyderabad. A customer simply gets a new location_sk on their next order.

with locations as (
    select distinct
        {{ dbt_utils.generate_surrogate_key(['country', 'state', 'city', 'postal_code']) }} as location_sk,
        country,
        state,
        city,
        postal_code,
        region
    from {{ ref('stg_superstore__orders') }}
)

select * from locations
```

**Why no snapshot for Locations?**
A location is *defined* by its attributes. "Bangalore, Karnataka, India" never changes. If a customer moves, they simply get linked to a brand new `location_sk` for Hyderabad on their next order.

---

## Phase 11: The Fact Table — Incremental + Point-in-Time Joins (Gold Layer)

This is the most complex and most important file in the entire project.

### `models/marts/sales/fct_orders.sql`
```sql
-- ============================================
-- CONFIG: Incremental materialization with upsert capability
-- ============================================
{{
    config(
        materialized='incremental',
        unique_key='order_item_id'   -- The "Upsert Anchor": if this key exists, UPDATE instead of INSERT
    )
}}

with staging as (
    select * from {{ ref('stg_superstore__orders') }}

    -- ============================================
    -- INCREMENTAL FILTER
    -- This block ONLY runs if the table already exists in the database.
    -- On the very first run (or --full-refresh), this is skipped entirely.
    -- On every subsequent run, it filters to only grab NEW orders.
    -- ============================================
    {% if is_incremental() %}
        where order_date >= (select max(order_date) from {{ this }})
        -- {{ this }} = a special dbt variable that refers to fct_orders itself
    {% endif %}
),

dim_customers as (
    select * from {{ ref('dim_customers') }}
),

dim_products as (
    select * from {{ ref('dim_products') }}
),

orders_fact as (
    select
        -- Primary Key
        staging.order_item_id,

        -- ============================================
        -- HISTORICAL SURROGATE KEYS (from Snapshots via Point-in-Time Joins)
        -- ============================================
        dim_customers.customer_sk,
        dim_products.product_sk,

        -- ============================================
        -- STATIC SURROGATE KEY (no snapshot needed for locations)
        -- ============================================
        {{ dbt_utils.generate_surrogate_key([
            'staging.country', 'staging.state', 'staging.city', 'staging.postal_code'
        ]) }} as location_sk,

        -- Degenerate Dimension (lives directly on the Fact, not in a Dimension table)
        staging.order_id,

        -- Date columns
        staging.order_date,
        staging.ship_date,
        staging.ship_mode,

        -- Measures / Metrics (the numbers analysts will SUM, AVG, COUNT)
        staging.sales,
        staging.quantity,
        staging.discount,
        staging.profit

    from staging

    -- ============================================
    -- POINT-IN-TIME JOIN: CUSTOMERS
    -- Ensures the order is linked to the exact version of the customer
    -- that existed on the date the sale occurred.
    -- ============================================
    left join dim_customers
        on staging.customer_id = dim_customers.customer_id
        and staging.order_date >= dim_customers.dbt_valid_from
        and staging.order_date < coalesce(dim_customers.dbt_valid_to, '2099-01-01')
        -- If dbt_valid_to is NULL, the record is currently active.
        -- COALESCE replaces NULL with a date far in the future so the comparison works.

    -- ============================================
    -- POINT-IN-TIME JOIN: PRODUCTS
    -- Same logic: links the order to the exact version of the product.
    -- ============================================
    left join dim_products
        on staging.product_id = dim_products.product_id
        and staging.order_date >= dim_products.dbt_valid_from
        and staging.order_date < coalesce(dim_products.dbt_valid_to, '2099-01-01')
)

select * from orders_fact
```

**Execution:**
```powershell
# First run: Full refresh to build the baseline table from scratch
dbt run --select fct_orders --full-refresh

# Every subsequent run: Only processes new/updated orders
dbt run --select fct_orders
```

**Why `unique_key='order_item_id'`?**
This is the "Upsert Anchor." If dbt pulls a row with `order_item_id = Hash_123` and that key already exists in the Fact table, dbt runs an `UPDATE` (overwrite) instead of an `INSERT` (duplicate). This prevents zombie duplicate rows.

**Why not use `updated_at` for the incremental filter?**
Our raw Superstore CSV dataset doesn't have an `updated_at` column. In a real production environment with a live database, we WOULD filter on `where updated_at >= (select max(updated_at) from {{ this }})` to catch both new orders AND modified old orders.

---

## Phase 12: Referential Integrity Testing

### `models/marts/sales/_sales__models.yml`
```yaml
version: 2

models:
  - name: fct_orders
    description: "The core fact table containing all order events and sales metrics."
    columns:
      - name: order_item_id
        description: "Primary key of the fact table."
        tests:
          - unique
          - not_null

      - name: customer_sk
        description: "Foreign key linking to the Customer Dimension."
        tests:
          - not_null
          - relationships:
              to: ref('dim_customers')
              field: customer_sk

      - name: product_sk
        description: "Foreign key linking to the Product Dimension."
        tests:
          - not_null
          - relationships:
              to: ref('dim_products')
              field: product_sk

      - name: location_sk
        description: "Foreign key linking to the Location Dimension."
        tests:
          - not_null
          - relationships:
              to: ref('dim_locations')
              field: location_sk
```

**What `relationships` tests do under the hood:**
dbt runs a query like:
```sql
SELECT customer_sk FROM fct_orders
WHERE customer_sk NOT IN (SELECT customer_sk FROM dim_customers);
```
If this returns even ONE row, the test fails. This guarantees every Fact row maps perfectly to a Dimension row.

**Ran:** `dbt test --select marts` → All tests passed with zero errors.

---

## Phase 13: Documentation & DAG Visualization

```powershell
dbt docs generate    # Reads all .yml descriptions and .sql files to build a docs site
dbt docs serve       # Launches the site at http://localhost:8080
```

The **Lineage Graph (DAG)** visually shows:
```
raw_orders → stg_superstore__orders → snp_customers → dim_customers ─┐
                                    → snp_products  → dim_products  ─┤
                                    → dim_locations ─────────────────┤
                                                                     └→ fct_orders
```

---

## Phase 14: BI Integration (Power BI / Tableau)

Because we handled ALL complex logic inside dbt, the BI developer's job is trivially simple:

1. **Connect** Power BI to `SUPERSTORE_ANALYTICS` using the `ANALYST_WH` warehouse and `ANALYST_ROLE`.
2. **Import** `fct_orders`, `dim_customers`, `dim_products`, `dim_locations`.
3. **Draw relationships** by dragging `customer_sk` from Fact → `customer_sk` in Dimension. Repeat for `product_sk` and `location_sk`.
4. **Write DAX measures** like `Total Sales = SUM(fct_orders[sales])`. Because the Point-in-Time joins already linked every order to the historically correct customer version, the DAX measure is automatically accurate across all time periods.

**No complex time-travel logic is needed in the dashboard. dbt already solved it.**

---

## Summary: The Complete Data Flow

```
Excel/CSV File (flat, messy, all text)
    │
    ▼
[Snowflake Stage] ── COPY INTO ──▶ RAW_ORDERS (all VARCHAR, Bronze)
    │
    ▼
[dbt Staging Layer] ── CAST, rename, generate PK ──▶ stg_superstore__orders (Silver VIEW)
    │
    ├──▶ [dbt Snapshot] ── track changes ──▶ snp_customers (SCD Type 2 TABLE)
    ├──▶ [dbt Snapshot] ── track changes ──▶ snp_products (SCD Type 2 TABLE)
    │
    ├──▶ dim_customers (Gold VIEW on snapshot)
    ├──▶ dim_products (Gold VIEW on snapshot)
    ├──▶ dim_locations (Gold VIEW on staging, static surrogate key)
    │
    └──▶ fct_orders (Gold TABLE, Incremental, Point-in-Time Joins)
              │
              ▼
         Power BI / Tableau (Star Schema, drag-and-drop relationships)
```
