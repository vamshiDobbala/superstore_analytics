{{
    config(
        materialized='view'
    )
}}

with orders as (
    select * from {{ ref('fct_orders') }}
),

customers as (
    select * from {{ ref('dim_customers') }}
),

products as (
    select * from {{ ref('dim_products') }}
),

locations as (
    select * from {{ ref('dim_locations') }}
)

select
    -- Order identifiers
    o.order_item_id,
    o.order_id,

    -- Dates
    o.order_date,
    o.ship_date,
    o.ship_mode,

    -- Customer attributes (from the version active at order time!)
    c.customer_id,
    c.customer_name,
    c.segment,

    -- Product attributes (from the version active at order time!)
    p.product_id,
    p.product_name,
    p.category,
    p.sub_category,

    -- Location attributes
    l.country,
    l.region,
    l.state,
    l.city,
    l.postal_code,

    -- Metrics
    o.sales,
    o.quantity,
    o.discount,
    o.profit

from orders o
left join customers c on o.customer_sk = c.customer_sk
left join products  p on o.product_sk  = p.product_sk
left join locations l on o.location_sk = l.location_sk
