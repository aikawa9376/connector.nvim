use anyhow::{bail, Context, Result};
use oracle_rs::{Config, Connection, QueryResult, Value as OracleValue};
use serde_json::{json, Value};
use url::Url;

use crate::driver::{Driver, DriverKind};
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};
use crate::sql::{qualify_table_name, quote_identifier, starts_with_row_query};
use crate::value::{normalize_json_value, normalized_key_values};

pub struct OracleDriver;

impl Driver for OracleDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
        let trimmed = query.trim().trim_end_matches(';').trim();
        if trimmed.is_empty() {
            bail!("query is empty");
        }

        block_on(async {
            let conn = oracle_connection(url).await?;
            if starts_with_row_query(trimmed) {
                query_result_to_response(conn.query(trimmed, &[]).await?)
            } else {
                let result = conn.execute(trimmed, &[]).await?;
                conn.commit().await?;
                Ok(ExecuteResponse {
                    columns: vec![ColumnMeta {
                        name: "affected_rows".to_string(),
                    }],
                    rows: vec![vec![json!(result.rows_affected)]],
                    row_count: 1,
                    message: None,
                })
            }
        })
    }

    fn structure(&self, url: &str) -> Result<Vec<StructureItem>> {
        block_on(async {
            let conn = oracle_connection(url).await?;
            let result = conn
                .query(
                    "
                    SELECT owner, object_name, object_type
                    FROM (
                        SELECT owner, table_name AS object_name, 'TABLE' AS object_type
                        FROM all_tables
                        UNION ALL
                        SELECT owner, table_name AS object_name, 'EXTERNAL TABLE' AS object_type
                        FROM all_external_tables
                        UNION ALL
                        SELECT owner, view_name AS object_name, 'VIEW' AS object_type
                        FROM all_views
                        UNION ALL
                        SELECT owner, mview_name AS object_name, 'MATERIALIZED VIEW' AS object_type
                        FROM all_mviews
                    )
                    WHERE owner IN (SELECT username FROM all_users WHERE common = 'NO')
                    ORDER BY owner, object_name
                    ",
                    &[],
                )
                .await?;

            let mut items = Vec::new();
            for row in result.rows {
                let object_type = oracle_value_to_string(row.get(2)).unwrap_or_default();
                items.push(StructureItem {
                    schema: oracle_value_to_string(row.get(0)),
                    name: oracle_value_to_string(row.get(1)).unwrap_or_default(),
                    materialization: match object_type.as_str() {
                        "VIEW" => "view".to_string(),
                        "MATERIALIZED VIEW" => "materialized_view".to_string(),
                        _ => "table".to_string(),
                    },
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
            let conn = oracle_connection(url).await?;
            let schema = schema
                .unwrap_or_else(|| oracle_default_schema(url).unwrap_or_default())
                .to_ascii_uppercase();
            let table = table.to_ascii_uppercase();
            let result = conn
                .query(
                    "
                    SELECT
                        col.column_name,
                        col.data_type,
                        col.nullable,
                        col.data_default,
                        col.column_id,
                        CASE WHEN pk.column_name IS NULL THEN 0 ELSE 1 END AS primary_key
                    FROM sys.all_tab_columns col
                    LEFT JOIN (
                        SELECT cons.owner, cols.table_name, cols.column_name
                        FROM all_constraints cons
                        JOIN all_cons_columns cols
                          ON cons.owner = cols.owner
                         AND cons.constraint_name = cols.constraint_name
                        WHERE cons.constraint_type = 'P'
                    ) pk
                      ON pk.owner = col.owner
                     AND pk.table_name = col.table_name
                     AND pk.column_name = col.column_name
                    WHERE col.owner = :1
                      AND col.table_name = :2
                    ORDER BY col.column_id
                    ",
                    &[schema.clone().into(), table.into()],
                )
                .await?;

            let mut columns = Vec::new();
            for row in result.rows {
                columns.push(ColumnInfo {
                    name: oracle_value_to_string(row.get(0)).unwrap_or_default(),
                    data_type: oracle_value_to_string(row.get(1)).unwrap_or_default(),
                    nullable: oracle_value_to_string(row.get(2))
                        .map(|value| value.eq_ignore_ascii_case("Y"))
                        .unwrap_or(true),
                    default_value: oracle_value_to_string(row.get(3)),
                    ordinal_position: oracle_value_to_i64(row.get(4)).unwrap_or_default(),
                    primary_key: oracle_value_to_i64(row.get(5)).unwrap_or_default() == 1,
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
        let current = parse_oracle_url(url)?.service;
        Ok(ListDatabasesResponse {
            current: current.clone(),
            available: vec![current],
        })
    }

    fn update_row(
        &self,
        url: &str,
        table: &str,
        schema: Option<&str>,
        column: &ColumnUpdateInput,
        keys: &[KeyFieldInput],
        value: &Value,
    ) -> Result<u64> {
        block_on(async {
            let conn = oracle_connection(url).await?;
            let mut params = vec![json_to_oracle_value(
                value,
                &column.data_type,
                column.nullable,
            )?];
            let mut clauses = Vec::new();

            for (name, data_type, key_value) in normalized_key_values(keys)? {
                if key_value.is_null() {
                    clauses.push(format!(
                        "{} IS NULL",
                        quote_identifier(DriverKind::Oracle, &name)
                    ));
                } else {
                    let param_index = params.len() + 1;
                    clauses.push(format!(
                        "{} = :{}",
                        quote_identifier(DriverKind::Oracle, &name),
                        param_index
                    ));
                    params.push(json_to_oracle_value(&key_value, &data_type, true)?);
                }
            }

            let query = format!(
                "UPDATE {} SET {} = :1 WHERE {}",
                qualify_table_name(DriverKind::Oracle, schema, table),
                quote_identifier(DriverKind::Oracle, &column.name),
                clauses.join(" AND ")
            );
            let result = conn.execute(&query, &params).await?;
            conn.commit().await?;
            Ok(result.rows_affected)
        })
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

async fn oracle_connection(url: &str) -> Result<Connection> {
    let parts = parse_oracle_url(url)?;
    let config = Config::new(
        parts.host,
        parts.port,
        parts.service,
        parts.username,
        parts.password,
    );
    Connection::connect_with_config(config)
        .await
        .context("failed to connect to oracle")
}

struct OracleConnectionParts {
    host: String,
    port: u16,
    service: String,
    username: String,
    password: String,
}

fn parse_oracle_url(raw: &str) -> Result<OracleConnectionParts> {
    let parsed =
        Url::parse(raw).with_context(|| format!("invalid oracle connection URL: {raw}"))?;
    if parsed.scheme() != "oracle" {
        bail!("oracle URL must use oracle://");
    }

    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("oracle URL requires a host"))?
        .to_string();
    let service = parsed.path().trim_start_matches('/').to_string();
    if service.is_empty() {
        bail!("oracle URL requires a service name in the path");
    }

    Ok(OracleConnectionParts {
        host,
        port: parsed.port().unwrap_or(1521),
        service,
        username: parsed.username().to_string(),
        password: parsed.password().unwrap_or_default().to_string(),
    })
}

fn oracle_default_schema(url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    let username = parsed.username();
    if username.is_empty() {
        None
    } else {
        Some(username.to_ascii_uppercase())
    }
}

fn query_result_to_response(result: QueryResult) -> Result<ExecuteResponse> {
    let columns = result
        .columns
        .iter()
        .map(|column| ColumnMeta {
            name: column.name.clone(),
        })
        .collect::<Vec<_>>();
    let rows = result
        .rows
        .iter()
        .map(|row| row.values().iter().map(oracle_value_to_json).collect())
        .collect::<Vec<Vec<_>>>();

    Ok(ExecuteResponse {
        row_count: rows.len(),
        columns,
        rows,
        message: None,
    })
}

fn oracle_value_to_json(value: &OracleValue) -> Value {
    match value {
        OracleValue::Null => Value::Null,
        OracleValue::String(value) => json!(value),
        OracleValue::Bytes(value) => json!(format!("<blob:{}>", value.len())),
        OracleValue::Integer(value) => json!(value),
        OracleValue::Float(value) => json!(value),
        OracleValue::Number(value) => json!(format!("{value:?}")),
        OracleValue::Date(value) => json!(format!("{value:?}")),
        OracleValue::Timestamp(value) => json!(format!("{value:?}")),
        OracleValue::RowId(value) => json!(value.to_string()),
        OracleValue::Boolean(value) => json!(value),
        OracleValue::Json(value) => value.clone(),
        OracleValue::Lob(value) => json!(format!("{value:?}")),
        OracleValue::Vector(value) => json!(format!("{value:?}")),
        OracleValue::Cursor(value) => json!(format!("{value:?}")),
        OracleValue::Collection(value) => json!(format!("{value:?}")),
    }
}

fn oracle_value_to_string(value: Option<&OracleValue>) -> Option<String> {
    match value? {
        OracleValue::Null => None,
        OracleValue::String(value) => Some(value.clone()),
        OracleValue::Integer(value) => Some(value.to_string()),
        OracleValue::Float(value) => Some(value.to_string()),
        OracleValue::Number(value) => Some(format!("{value:?}")),
        other => Some(oracle_value_to_json(other).to_string()),
    }
}

fn oracle_value_to_i64(value: Option<&OracleValue>) -> Option<i64> {
    match value? {
        OracleValue::Integer(value) => Some(*value),
        OracleValue::Float(value) => Some(*value as i64),
        OracleValue::Number(value) => value.to_i64().ok(),
        OracleValue::String(value) => value.parse().ok(),
        _ => None,
    }
}

fn json_to_oracle_value(value: &Value, data_type: &str, nullable: bool) -> Result<OracleValue> {
    let normalized = normalize_json_value(value, data_type, nullable)?;
    Ok(match normalized {
        Value::Null => OracleValue::Null,
        Value::Bool(value) => OracleValue::Boolean(value),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                OracleValue::Integer(integer)
            } else {
                OracleValue::Float(
                    number
                        .as_f64()
                        .ok_or_else(|| anyhow::anyhow!("invalid numeric value"))?,
                )
            }
        }
        Value::String(value) => OracleValue::String(value),
        other => OracleValue::Json(other),
    })
}
