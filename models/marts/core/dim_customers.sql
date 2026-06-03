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
        -- We rename dbt's secret ID to match our Kimball naming convention
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