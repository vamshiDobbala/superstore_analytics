{% snapshot snp_customers %}

{{
    config(
      target_schema='snapshots',
      unique_key='customer_id',
      strategy='check',
      check_cols=['customer_name', 'segment']
    )
}}

select distinct
    customer_id,
    customer_name,
    segment
from {{ ref('stg_superstore__orders') }}

{% endsnapshot %}