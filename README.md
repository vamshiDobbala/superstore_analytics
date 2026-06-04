# Superstore Analytics Data Warehouse 🚀

This repository contains a production-grade **dbt (data build tool)** project that transforms raw e-commerce sales data into a robust, analytics-ready Kimball Star Schema. 

This project was built to showcase advanced Data Engineering and Analytics Engineering concepts, focusing on data modeling, historical tracking, and pipeline optimization.

## 🛠️ Tech Stack
* **Transformation Engine:** dbt (Data Build Tool)
* **Architecture:** Kimball Dimensional Modeling (Star Schema)
* **SQL Dialect:** Snowflake / BigQuery compatible
* **Package Management:** `dbt_utils`

---

## 🏗️ Architecture & Pipeline Flow

The pipeline is structured using a Medallion-style ELT architecture:

1. **Staging Layer (Silver):** 
   - Reads raw source data (`raw_orders`).
   - Cleans up column names, enforces strict datatype casting (`VARCHAR` to `DATE`/`FLOAT`), and generates deterministic **Surrogate Keys** for line items to establish a primary key.
2. **Snapshot Layer (History Engine):** 
   - Implements **SCD Type 2** (Slowly Changing Dimensions) using dbt Snapshots.
   - Automatically tracks historical changes to `dim_customers` and `dim_products` by monitoring changes in attributes (e.g., segment, category) and managing `dbt_valid_from` and `dbt_valid_to` timestamps.
3. **Marts Layer (Gold - Star Schema):** 
   - **Dimensions:** Built as lightweight `views` on top of Snapshots and Staging to provide descriptive attributes (Customers, Products, Locations).
   - **Fact Table:** The core `fct_orders` table housing all transactional metrics.

---

## 🌟 Key Features Showcased

### 1. Slowly Changing Dimensions (SCD Type 2)
Instead of overwriting historical data, this project uses **dbt Snapshots** to track the evolution of Customers and Products. If a customer changes segments, the pipeline automatically "closes" their old record and opens a new one, ensuring historical revenue reporting remains 100% accurate.

### 2. Point-in-Time Joins
The `fct_orders` table does not rely on static joins. It uses complex **Point-in-Time `LEFT JOINS`** against the snapshot dimensions. This guarantees that an order is linked to the *exact version* of the customer or product that existed at the exact moment the sale occurred.

### 3. Incremental Materialization
To optimize compute costs and pipeline runtime, the core `fct_orders` table is materialized **incrementally**. Instead of running full table scans and rebuilding history every day, it dynamically filters for `MAX(order_date)` and uses an upsert strategy (`unique_key`) to only process brand new or updated records.

### 4. Data Quality & Referential Integrity
The pipeline is strictly governed by YAML-configured data tests:
- `unique` and `not_null` constraints on all Primary Keys.
- **Referential Integrity (`relationships`) tests** to guarantee that every foreign key in the Fact table perfectly maps to an existing record in the Dimension tables.

---

## 📁 Repository Structure

```text
├── models/
│   ├── staging/          # Light transformations, casting, and PK generation
│   ├── marts/
│   │   ├── core/         # Dimension tables (Customers, Products, Locations)
│   │   └── sales/        # Fact tables (fct_orders)
├── snapshots/            # SCD Type 2 logic (snp_customers, snp_products)
├── dbt_project.yml       # Global configurations and materialization rules
└── packages.yml          # External dbt dependencies (dbt_utils)
```

## 🚀 How to Run

1. Clone the repository.
2. Ensure you have dbt installed and your `profiles.yml` configured to your data warehouse.
3. Install dependencies:
   ```bash
   dbt deps
   ```
4. Build the snapshots (initial baseline):
   ```bash
   dbt snapshot
   ```
5. Run the models:
   ```bash
   dbt run 
   ```
6. Test the data quality:
   ```bash
   dbt test
   ```
7. Generate and view the documentation/DAG:
   ```bash
   dbt docs generate
   dbt docs serve
   ```
