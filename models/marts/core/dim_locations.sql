{{ config(materialized='view') }}

with staging as (
    select * from {{ ref('stg_superstore__orders') }}
),
locations as (
    select distinct
        {{ dbt_utils.generate_surrogate_key(['country', 'state', 'city', 'postal_code']) }} as location_sk,
        country,
        region,
        state,
        city,
        postal_code
    from staging
)
select * from locations