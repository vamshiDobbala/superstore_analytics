with source as (

    select * from {{ source('superstore', 'raw_orders') }}

),

renamed as (

    select
        -- Primary Key
        {{ dbt_utils.generate_surrogate_key(['order_id', 'product_id']) }} as order_item_id,

        -- Foreign Keys / Identifiers
        order_id,
        product_id,
        customer_id,
        
        -- Customer details
        customer_name,
        segment,

        -- Geography
        country,
        city,
        state,
        postal_code,
        region,

        -- Product details
        category,
        sub_category,
        product_name,

        -- Dates (Casting from VARCHAR to DATE)
        cast(order_date as date) as order_date,
        cast(ship_date as date) as ship_date,
        ship_mode,

        -- Metrics (Casting from VARCHAR to NUMERIC types)
        cast(sales as float) as sales,
        cast(quantity as integer) as quantity,
        cast(discount as float) as discount,
        cast(profit as float) as profit

    from source

)

select * from renamed