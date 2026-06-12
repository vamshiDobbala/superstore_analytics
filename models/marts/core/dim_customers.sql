{{ 
    config(
        materialized='view'
    ) 
}}
with snapshot as (

    select * from {{ ref('snp_customers') }}

),

customers as (

    select
        -- Each version of a customer gets a unique surrogate key (SCD Type 2)
        dbt_scd_id as customer_sk, 
        
        customer_id,
        customer_name,
        segment,
        
        -- We expose the time-travel dates so the Fact table can use them!
        dbt_valid_from,
        dbt_valid_to
        
    from snapshot

)

select * from customers