{{
    config(
        materialized='incremental',
        unique_key='order_item_id'
    )
}}

with staging as (
    select * from {{ ref('stg_superstore__orders') }}
    {% if is_incremental() %}
        where order_date >= (select max(order_date) from {{ this }})
    {% endif %} 
),
orders_fact as (
    select
        -- Primary Key for the Fact table
        order_item_id,

        -- Surrogate Foreign Keys (links perfectly to our dimensions!)
        {{ dbt_utils.generate_surrogate_key(['customer_id']) }} as customer_sk,
        {{ dbt_utils.generate_surrogate_key(['product_id']) }} as product_sk,
        {{ dbt_utils.generate_surrogate_key(['country', 'state', 'city', 'postal_code']) }} as location_sk,
        
        -- Degenerate Dimension (No separate dim_orders table needed)
        order_id,
        
        -- Dates
        order_date,
        ship_date,
        ship_mode,

        -- Metrics / Measures
        sales,
        quantity,
        discount,
        profit
    from staging
)
select * from orders_fact