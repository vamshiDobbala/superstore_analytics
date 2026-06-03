{% snapshot snp_products %}

{{
    config(
      target_schema='snapshots',
      unique_key='product_id',
      strategy='check',
      check_cols=['category', 'sub_category', 'product_name']
    )
}}

select distinct
    product_id,
    category,
    sub_category,
    product_name
from {{ ref('stg_superstore__orders') }}
{% endsnapshot %}