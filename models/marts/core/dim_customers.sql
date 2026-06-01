with staging as (
    select * from {{ ref('stg_superstore__orders') }}
),
customers as (
    select distinct
        {{ dbt_utils.generate_surrogate_key(['customer_id']) }} as customer_sk,
        customer_id,
        customer_name,
        segment
    from staging
)
select * from customers