with staging as (
    select * from {{ ref('stg_superstore__orders') }}
),
products as (
    select distinct
        {{ dbt_utils.generate_surrogate_key(['product_id']) }} as product_sk,
        product_id,
        category,
        sub_category,
        product_name
    from staging
)
select * from products