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