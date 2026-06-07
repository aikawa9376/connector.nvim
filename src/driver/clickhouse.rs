use anyhow::{bail, Context, Result};
use chrono::NaiveDate;
use clickhouse_rs::types::{Complex, Decimal, Enum16, Enum8, Row, SqlType};
use clickhouse_rs::{Block, Pool};
use serde_json::{json, Value};

use crate::driver::Driver;
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};
use crate::sql::starts_with_row_query;

pub struct ClickhouseDriver;

impl Driver for ClickhouseDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
        let trimmed = query.trim().trim_end_matches(';').trim();
        if trimmed.is_empty() {
            bail!("query is empty");
        }

        block_on(async {
            let mut client = clickhouse_handle(url).await?;
            if starts_with_row_query(trimmed) {
                let block = client.query(trimmed).fetch_all().await?;
                block_to_response(block)
            } else {
                client.execute(trimmed).await?;
                Ok(ExecuteResponse {
                    columns: vec![ColumnMeta {
                        name: "status".to_string(),
                    }],
                    rows: vec![vec![json!("ok")]],
                    row_count: 1,
                    message: Some("statement executed".to_string()),
                })
            }
        })
    }

    fn structure(&self, url: &str) -> Result<Vec<StructureItem>> {
        block_on(async {
            let mut client = clickhouse_handle(url).await?;
            let block = client
                .query(
                    "
                    SELECT
                        database AS table_schema,
                        name AS table_name,
                        multiIf(
                            engine = 'View', 'view',
                            engine = 'MaterializedView', 'materialized_view',
                            engine = 'LiveView', 'view',
                            'table'
                        ) AS table_type
                    FROM system.tables
                    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
                    ORDER BY database, name
                    ",
                )
                .fetch_all()
                .await?;
            let mut items = Vec::new();
            for row in block.rows() {
                items.push(StructureItem {
                    schema: Some(row.get::<String, _>("table_schema")?),
                    name: row.get::<String, _>("table_name")?,
                    materialization: row.get::<String, _>("table_type")?,
                });
            }
            Ok(items)
        })
    }

    fn columns(
        &self,
        url: &str,
        table: &str,
        schema: Option<String>,
        _materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>> {
        block_on(async {
            let mut client = clickhouse_handle(url).await?;
            let database = match schema {
                Some(value) => value,
                None => current_database(&mut client).await?,
            };
            let query = format!(
                "
                SELECT name, type, default_expression, position
                FROM system.columns
                WHERE database = '{}' AND table = '{}'
                ORDER BY position
                ",
                escape_sql_literal(&database),
                escape_sql_literal(table)
            );
            let block = client.query(query).fetch_all().await?;
            let mut columns = Vec::new();
            for row in block.rows() {
                let data_type = row.get::<String, _>("type")?;
                let default_value = row.get::<String, _>("default_expression")?;
                columns.push(ColumnInfo {
                    name: row.get::<String, _>("name")?,
                    nullable: data_type.starts_with("Nullable("),
                    data_type,
                    default_value: if default_value.is_empty() {
                        None
                    } else {
                        Some(default_value)
                    },
                    ordinal_position: row.get::<u64, _>("position")? as i64,
                    primary_key: false,
                });
            }
            Ok(columns)
        })
    }

    fn list_databases(
        &self,
        url: &str,
        _connection: &ConnectionInput,
    ) -> Result<ListDatabasesResponse> {
        block_on(async {
            let mut client = clickhouse_handle(url).await?;
            let block = client
                .query(
                    "
                    SELECT currentDatabase() AS current_db, name AS database_name
                    FROM system.databases
                    ORDER BY name
                    ",
                )
                .fetch_all()
                .await?;
            let mut current = String::new();
            let mut available = Vec::new();
            for row in block.rows() {
                if current.is_empty() {
                    current = row.get::<String, _>("current_db")?;
                }
                available.push(row.get::<String, _>("database_name")?);
            }
            Ok(ListDatabasesResponse { current, available })
        })
    }

    fn update_row(
        &self,
        _url: &str,
        _table: &str,
        _schema: Option<&str>,
        _column: &ColumnUpdateInput,
        _keys: &[KeyFieldInput],
        _value: &Value,
    ) -> Result<u64> {
        bail!("row updates are not supported for clickhouse")
    }
}

fn block_on<T, F>(future: F) -> Result<T>
where
    F: std::future::Future<Output = Result<T>>,
{
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("failed to create tokio runtime")?
        .block_on(future)
}

async fn clickhouse_handle(url: &str) -> Result<clickhouse_rs::ClientHandle> {
    let pool = Pool::new(normalize_clickhouse_url(url)?);
    Ok(pool.get_handle().await?)
}

fn normalize_clickhouse_url(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok("tcp://127.0.0.1:9000".to_string());
    }
    if let Some(rest) = trimmed.strip_prefix("clickhouse://") {
        return Ok(format!("tcp://{rest}"));
    }
    if trimmed.contains("://") {
        return Ok(trimmed.to_string());
    }
    Ok(format!("tcp://{trimmed}"))
}

async fn current_database(client: &mut clickhouse_rs::ClientHandle) -> Result<String> {
    let block = client
        .query("SELECT currentDatabase() AS current_db")
        .fetch_all()
        .await?;
    let row = block
        .rows()
        .next()
        .context("failed to determine current clickhouse database")?;
    Ok(row.get::<String, _>("current_db")?)
}

fn block_to_response(block: Block<Complex>) -> Result<ExecuteResponse> {
    let columns = block
        .columns()
        .iter()
        .map(|column| ColumnMeta {
            name: column.name().to_string(),
        })
        .collect::<Vec<_>>();
    let mut rows = Vec::new();
    for row in block.rows() {
        let mut values = Vec::new();
        for index in 0..columns.len() {
            values.push(clickhouse_cell_to_json(&row, index)?);
        }
        rows.push(values);
    }
    Ok(ExecuteResponse {
        row_count: rows.len(),
        columns,
        rows,
        message: None,
    })
}

fn clickhouse_cell_to_json(row: &Row<'_, Complex>, index: usize) -> Result<Value> {
    let sql_type = row.sql_type(index)?;
    match sql_type {
        SqlType::Nullable(inner) => nullable_clickhouse_cell_to_json(row, index, inner),
        SqlType::Bool => Ok(json!(row.get::<bool, _>(index)?)),
        SqlType::UInt8 => Ok(json!(row.get::<u8, _>(index)?)),
        SqlType::UInt16 => Ok(json!(row.get::<u16, _>(index)?)),
        SqlType::UInt32 => Ok(json!(row.get::<u32, _>(index)?)),
        SqlType::UInt64 => Ok(json!(row.get::<u64, _>(index)?)),
        SqlType::Int8 => Ok(json!(row.get::<i8, _>(index)?)),
        SqlType::Int16 => Ok(json!(row.get::<i16, _>(index)?)),
        SqlType::Int32 => Ok(json!(row.get::<i32, _>(index)?)),
        SqlType::Int64 => Ok(json!(row.get::<i64, _>(index)?)),
        SqlType::Float32 => Ok(json!(row.get::<f32, _>(index)?)),
        SqlType::Float64 => Ok(json!(row.get::<f64, _>(index)?)),
        SqlType::String | SqlType::FixedString(_) => match row.get::<String, _>(index) {
            Ok(value) => Ok(json!(value)),
            Err(_) => Ok(json!(format!(
                "<blob:{}>",
                row.get::<Vec<u8>, _>(index)?.len()
            ))),
        },
        SqlType::Date => Ok(json!(row.get::<NaiveDate, _>(index)?.to_string())),
        SqlType::DateTime(_) => Ok(json!(row
            .get::<chrono::DateTime<chrono_tz::Tz>, _>(index)?
            .to_rfc3339())),
        SqlType::Ipv4 => Ok(json!(row.get::<std::net::Ipv4Addr, _>(index)?.to_string())),
        SqlType::Ipv6 => Ok(json!(row.get::<std::net::Ipv6Addr, _>(index)?.to_string())),
        SqlType::Uuid => Ok(json!(row.get::<uuid::Uuid, _>(index)?.to_string())),
        SqlType::Decimal(_, _) => Ok(json!(row.get::<Decimal, _>(index)?.to_string())),
        SqlType::Enum8(_) => Ok(json!(row.get::<Enum8, _>(index)?.to_string())),
        SqlType::Enum16(_) => Ok(json!(row.get::<Enum16, _>(index)?.to_string())),
        SqlType::SimpleAggregateFunction(_, inner) => {
            simple_clickhouse_cell_to_json(row, index, inner)
        }
        other => Ok(json!(format!("<{}>", other))),
    }
}

fn nullable_clickhouse_cell_to_json(
    row: &Row<'_, Complex>,
    index: usize,
    inner: &'static SqlType,
) -> Result<Value> {
    match inner {
        SqlType::Bool => option_to_json(row.get::<Option<bool>, _>(index)?),
        SqlType::UInt8 => option_to_json(row.get::<Option<u8>, _>(index)?),
        SqlType::UInt16 => option_to_json(row.get::<Option<u16>, _>(index)?),
        SqlType::UInt32 => option_to_json(row.get::<Option<u32>, _>(index)?),
        SqlType::UInt64 => option_to_json(row.get::<Option<u64>, _>(index)?),
        SqlType::Int8 => option_to_json(row.get::<Option<i8>, _>(index)?),
        SqlType::Int16 => option_to_json(row.get::<Option<i16>, _>(index)?),
        SqlType::Int32 => option_to_json(row.get::<Option<i32>, _>(index)?),
        SqlType::Int64 => option_to_json(row.get::<Option<i64>, _>(index)?),
        SqlType::Float32 => option_to_json(row.get::<Option<f32>, _>(index)?),
        SqlType::Float64 => option_to_json(row.get::<Option<f64>, _>(index)?),
        SqlType::String | SqlType::FixedString(_) => {
            option_to_json(row.get::<Option<String>, _>(index)?)
        }
        SqlType::Date => option_to_json_string(row.get::<Option<NaiveDate>, _>(index)?),
        SqlType::DateTime(_) => option_to_json_string(
            row.get::<Option<chrono::DateTime<chrono_tz::Tz>>, _>(index)?
                .map(|value| value.to_rfc3339()),
        ),
        SqlType::Ipv4 => option_to_json_string(
            row.get::<Option<std::net::Ipv4Addr>, _>(index)?
                .map(|value| value.to_string()),
        ),
        SqlType::Ipv6 => option_to_json_string(
            row.get::<Option<std::net::Ipv6Addr>, _>(index)?
                .map(|value| value.to_string()),
        ),
        SqlType::Uuid => option_to_json_string(
            row.get::<Option<uuid::Uuid>, _>(index)?
                .map(|value| value.to_string()),
        ),
        SqlType::Decimal(_, _) => option_to_json_string(
            row.get::<Option<Decimal>, _>(index)?
                .map(|value| value.to_string()),
        ),
        SqlType::Enum8(_) => option_to_json_string(
            row.get::<Option<Enum8>, _>(index)?
                .map(|value| value.to_string()),
        ),
        SqlType::Enum16(_) => option_to_json_string(
            row.get::<Option<Enum16>, _>(index)?
                .map(|value| value.to_string()),
        ),
        SqlType::SimpleAggregateFunction(_, nested) => {
            nullable_clickhouse_cell_to_json(row, index, nested)
        }
        other => Ok(json!(format!("<Nullable({})>", other))),
    }
}

fn simple_clickhouse_cell_to_json(
    row: &Row<'_, Complex>,
    index: usize,
    inner: &'static SqlType,
) -> Result<Value> {
    match inner {
        SqlType::Nullable(nested) => nullable_clickhouse_cell_to_json(row, index, nested),
        _ => {
            let fake = row.sql_type(index)?;
            match fake {
                SqlType::SimpleAggregateFunction(_, nested) if nested == inner => match inner {
                    SqlType::UInt64 => Ok(json!(row.get::<u64, _>(index)?)),
                    SqlType::Int64 => Ok(json!(row.get::<i64, _>(index)?)),
                    SqlType::Float64 => Ok(json!(row.get::<f64, _>(index)?)),
                    SqlType::String => Ok(json!(row.get::<String, _>(index)?)),
                    other => Ok(json!(format!("<{}>", other))),
                },
                other => Ok(json!(format!("<{}>", other))),
            }
        }
    }
}

fn option_to_json<T: serde::Serialize>(value: Option<T>) -> Result<Value> {
    Ok(match value {
        Some(value) => serde_json::to_value(value)?,
        None => Value::Null,
    })
}

fn option_to_json_string<T: ToString>(value: Option<T>) -> Result<Value> {
    Ok(match value {
        Some(value) => json!(value.to_string()),
        None => Value::Null,
    })
}

fn escape_sql_literal(value: &str) -> String {
    value.replace('\'', "''")
}
