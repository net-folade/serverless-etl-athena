import os
import pandas as pd
import boto3

from urllib.parse import unquote_plus
from io import BytesIO

s3=boto3.client('s3')

REQUIRED_FIELDS = [
    "transaction_id",
    "date",
    "unit_price",
    "total_revenue",
    "units_sold",
    "product_category",
    "product_name",
    "region"
    ]

def transform(data):
    '''clean and normalize the raw data'''

    # normalize columns
    data.columns = [col.lower().replace(' ', '_') for col in data.columns]

    # normalize region
    data['region'] = data['region'].str.lower().str.replace(' ', '_')

    # drop rows missing required fields
    before = len(data)
    data = data.dropna(subset=REQUIRED_FIELDS)
    print(f"rows: {before} -> {len(data)}")

    # define column types for conversion
    data=data.astype({
        'transaction_id': str,
        'unit_price': float,
        'total_revenue': float,
        'units_sold': int,
        'product_category': str,
        'product_name': str,
        'region': str
        })
    
    # date32 in Parquet, matching Glue type `date`
    data['date'] = pd.to_datetime(data['date']).dt.date

    # verify total_revenue against units_sold * unit_price
    expected = (data['units_sold'] * data['unit_price']).round(2)
    mismatch = (data['total_revenue'].round(2) - expected).abs() > 0.01
    if mismatch.any():
        print(f"WARN: {mismatch.sum()} rows where total_revenue "
              f"!= units_sold * unit_price")
        print(data.loc[mismatch, ['transaction_id', 'units_sold',
                                  'unit_price', 'total_revenue']].to_string())
        
    return data

def lambda_handler(event, context):
    # s3 sends one record per notification for this event type
    record=event['Records'][0]['s3']
    bucket=record['bucket']['name']
    key=unquote_plus(record['object']['key'])

    if not key.startswith('raw/'):
        print(f"skipping {key} (not under raw/)")
        return
    
    print(f"processing s3://{bucket}/{key}")
    
    
    obj=s3.get_object(Bucket=bucket, Key=key)
    data=pd.read_csv(obj['Body'])

    data=transform(data)

    # get the basename of the file without extension
    basename=os.path.splitext(os.path.basename(key))[0]
    
    # group rows by region 
    # convert to parquet
    for region, group in data.groupby('region'):
        group=group.drop(columns=['region'])
        buffer = BytesIO()

        group.to_parquet(
            buffer,
            engine='pyarrow',
            compression='snappy',
            index=False
        )

        output_key=(f'processed/region={region}/{basename}.parquet')

        s3.put_object(
            Bucket=bucket,
            Key=output_key,
            Body=buffer.getvalue()
        )
        print(f'wrote {output_key} ({len(group)} rows)')
