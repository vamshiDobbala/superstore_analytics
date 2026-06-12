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

-- Pull in SCD2 dimensions for date-range lookup
-- The earliest snapshot version is extended back to 1900-01-01
-- so that historical orders before the first snapshot can still match
dim_customers as (
    select
        customer_sk,
        customer_id,
        case
            when row_number() over (partition by customer_id order by dbt_valid_from asc) = 1
            then '1900-01-01'::timestamp
            else dbt_valid_from
        end as dbt_valid_from,
        dbt_valid_to
    from {{ ref('dim_customers') }}
),

dim_products as (
    select
        product_sk,
        product_id,
        case
            when row_number() over (partition by product_id order by dbt_valid_from asc) = 1
            then '1900-01-01'::timestamp
            else dbt_valid_from
        end as dbt_valid_from,
        dbt_valid_to
    from {{ ref('dim_products') }}
),

orders_fact as (
    select
        -- Primary Key for the Fact table
        stg.order_item_id,

        -- SCD2 Surrogate Foreign Keys (date-range join picks the correct version!)
        dc.customer_sk,
        dp.product_sk,
        {{ dbt_utils.generate_surrogate_key(['stg.country', 'stg.state', 'stg.city', 'stg.postal_code']) }} as location_sk,
        
        -- Degenerate Dimension
        stg.order_id,
        
        -- Dates
        stg.order_date,
        stg.ship_date,
        stg.ship_mode,

        -- Metrics / Measures
        stg.sales,
        stg.quantity,
        stg.discount,
        stg.profit

    from staging stg

    -- SCD2 join: match the customer version that was active on the order date
    left join dim_customers dc
        on stg.customer_id = dc.customer_id
        and stg.order_date >= dc.dbt_valid_from
        and (stg.order_date < dc.dbt_valid_to or dc.dbt_valid_to is null)

    -- SCD2 join: match the product version that was active on the order date
    left join dim_products dp
        on stg.product_id = dp.product_id
        and stg.order_date >= dp.dbt_valid_from
        and (stg.order_date < dp.dbt_valid_to or dp.dbt_valid_to is null)
)

select * from orders_fact