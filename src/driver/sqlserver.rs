use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tiberius::{AuthMethod, Client, ColumnData, Config, EncryptionLevel, ToSql};
use tokio::net::TcpStream;
use tokio_util::compat::{Compat, TokioAsyncWriteCompatExt};
use url::Url;

use crate::driver::{Driver, DriverKind};
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};
use crate::sql::{qualify_table_name, quote_identifier, starts_with_row_query};
use crate::value::{normalize_json_value, normalized_key_values};

pub struct SqlServerDriver;

type SqlServerClient = Client<Compat<TcpStream>>;

impl Driver for SqlServerDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
        let trimmed = query.trim().trim_end_matches(';').trim();
        if trimmed.is_empty() {
            bail!("query is empty");
        }

        block_on(async {
            let mut client = sqlserver_client(url).await?;
            if starts_with_row_query(trimmed) {
                let result = client
                    .query(trimmed, &[])
                    .await?
                    .into_first_result()
                    .await?;
                rows_to_response(result)
            } else {
                let result = client.execute(trimmed, &[]).await?;
                let affected_rows = result.total();
                Ok(ExecuteResponse {
                    columns: vec![ColumnMeta {
                        name: "affected_rows".to_string(),
                    }],
                    rows: vec![vec![json!(affected_rows)]],
                    row_count: 1,
                    message: None,
                })
            }
        })
    }

    fn structure(&self, url: &str) -> Result<Vec<StructureItem>> {
        block_on(async {
            let mut client = sqlserver_client(url).await?;
            let result = client
                .query(
                    "
                    SELECT table_schema, table_name, table_type
                    FROM information_schema.tables
                    ORDER BY table_schema, table_name
                    ",
                    &[],
                )
                .await?
                .into_first_result()
                .await?;
            let mut items = Vec::new();
            for row in result {
                let table_type = row.get::<&str, _>("table_type").unwrap_or_default();
                items.push(StructureItem {
                    schema: row.get::<&str, _>("table_schema").map(str::to_string),
                    name: row
                        .get::<&str, _>("table_name")
                        .unwrap_or_default()
                        .to_string(),
                    materialization: if table_type.eq_ignore_ascii_case("VIEW") {
                        "view".to_string()
                    } else {
                        "table".to_string()
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
            let mut client = sqlserver_client(url).await?;
            let schema = match schema {
                Some(value) => value,
                None => "dbo".to_string(),
            };
            let result = client
                .query(
                    "
                    SELECT
                        c.column_name,
                        c.data_type,
                        c.is_nullable,
                        c.column_default,
                        c.ordinal_position,
                        CASE WHEN pk.column_name IS NULL THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END AS primary_key
                    FROM information_schema.columns c
                    LEFT JOIN (
                        SELECT kcu.table_schema, kcu.table_name, kcu.column_name
                        FROM information_schema.table_constraints tc
                        JOIN information_schema.key_column_usage kcu
                          ON tc.constraint_name = kcu.constraint_name
                         AND tc.table_schema = kcu.table_schema
                        WHERE tc.constraint_type = 'PRIMARY KEY'
                    ) pk
                      ON pk.table_schema = c.table_schema
                     AND pk.table_name = c.table_name
                     AND pk.column_name = c.column_name
                    WHERE c.table_schema = @P1 AND c.table_name = @P2
                    ORDER BY c.ordinal_position
                    ",
                    &[&schema, &table],
                )
                .await?
                .into_first_result()
                .await?;
            let mut columns = Vec::new();
            for row in result {
                columns.push(ColumnInfo {
                    name: row
                        .get::<&str, _>("column_name")
                        .unwrap_or_default()
                        .to_string(),
                    data_type: row
                        .get::<&str, _>("data_type")
                        .unwrap_or_default()
                        .to_string(),
                    nullable: row
                        .get::<&str, _>("is_nullable")
                        .unwrap_or_default()
                        .eq_ignore_ascii_case("YES"),
                    default_value: row.get::<&str, _>("column_default").map(str::to_string),
                    ordinal_position: row.get::<i32, _>("ordinal_position").unwrap_or_default()
                        as i64,
                    primary_key: row.get::<bool, _>("primary_key").unwrap_or(false),
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
            let mut client = sqlserver_client(url).await?;
            let result = client
                .query(
                    "
                    SELECT DB_NAME() AS current_db, name AS database_name
                    FROM sys.databases
                    ORDER BY name
                    ",
                    &[],
                )
                .await?
                .into_first_result()
                .await?;
            let mut current = String::new();
            let mut available = Vec::new();
            for row in result {
                if current.is_empty() {
                    current = row
                        .get::<&str, _>("current_db")
                        .unwrap_or_default()
                        .to_string();
                }
                available.push(
                    row.get::<&str, _>("database_name")
                        .unwrap_or_default()
                        .to_string(),
                );
            }
            Ok(ListDatabasesResponse { current, available })
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
            let mut client = sqlserver_client(url).await?;
            let mut params = vec![json_to_tiberius_param(
                value,
                &column.data_type,
                column.nullable,
            )?];
            let mut clauses = Vec::new();

            for (name, data_type, key_value) in normalized_key_values(keys)? {
                if key_value.is_null() {
                    clauses.push(format!(
                        "{} IS NULL",
                        quote_identifier(DriverKind::SqlServer, &name)
                    ));
                } else {
                    let param_index = params.len() + 1;
                    clauses.push(format!(
                        "{} = @P{}",
                        quote_identifier(DriverKind::SqlServer, &name),
                        param_index
                    ));
                    params.push(json_to_tiberius_param(&key_value, &data_type, true)?);
                }
            }

            let query = format!(
                "UPDATE {} SET {} = @P1 WHERE {}",
                qualify_table_name(DriverKind::SqlServer, schema, table),
                quote_identifier(DriverKind::SqlServer, &column.name),
                clauses.join(" AND ")
            );
            let param_refs = params
                .iter()
                .map(|value| value.as_ref() as &dyn ToSql)
                .collect::<Vec<_>>();
            let result = client.execute(query, &param_refs).await?;
            Ok(result.total())
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

async fn sqlserver_client(url: &str) -> Result<SqlServerClient> {
    let config = sqlserver_config(url)?;
    let tcp = TcpStream::connect(config.get_addr()).await?;
    tcp.set_nodelay(true)?;
    Ok(Client::connect(config, tcp.compat_write()).await?)
}

fn sqlserver_config(raw: &str) -> Result<Config> {
    let trimmed = raw.trim();
    if trimmed
        .to_ascii_lowercase()
        .starts_with("jdbc:sqlserver://")
    {
        return Ok(Config::from_jdbc_string(trimmed)?);
    }
    if trimmed.contains(';') && trimmed.contains('=') {
        return Ok(Config::from_ado_string(trimmed)?);
    }

    let parsed =
        Url::parse(trimmed).with_context(|| format!("invalid sqlserver connection URL: {raw}"))?;
    let mut config = Config::new();
    config.host(
        parsed
            .host_str()
            .ok_or_else(|| anyhow::anyhow!("sqlserver URL requires a host"))?,
    );
    config.port(parsed.port().unwrap_or(1433));

    let database = parsed.path().trim_start_matches('/');
    if !database.is_empty() {
        config.database(database);
    }

    if !parsed.username().is_empty() {
        config.authentication(AuthMethod::sql_server(
            parsed.username(),
            parsed.password().unwrap_or_default(),
        ));
    }

    let query = parsed.query_pairs().collect::<Vec<_>>();
    let truthy = |key: &str| {
        query.iter().any(|(name, value)| {
            name.eq_ignore_ascii_case(key)
                && matches!(value.to_ascii_lowercase().as_str(), "1" | "true" | "yes")
        })
    };
    let falsy = |key: &str| {
        query.iter().any(|(name, value)| {
            name.eq_ignore_ascii_case(key)
                && matches!(value.to_ascii_lowercase().as_str(), "0" | "false" | "no")
        })
    };

    if truthy("trust_cert") || truthy("trustServerCertificate") {
        config.trust_cert();
    }
    if falsy("encrypt")
        || query.iter().any(|(name, value)| {
            name.eq_ignore_ascii_case("encryption")
                && matches!(value.to_ascii_lowercase().as_str(), "off" | "false" | "no")
        })
    {
        config.encryption(EncryptionLevel::NotSupported);
    }

    Ok(config)
}

fn rows_to_response(rows: Vec<tiberius::Row>) -> Result<ExecuteResponse> {
    let columns = rows
        .first()
        .map(|row| {
            row.columns()
                .iter()
                .map(|column| ColumnMeta {
                    name: column.name().to_string(),
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let values = rows
        .iter()
        .map(|row| {
            row.cells()
                .map(|(_, value)| sqlserver_value_to_json(value))
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();

    Ok(ExecuteResponse {
        row_count: values.len(),
        columns,
        rows: values,
        message: None,
    })
}

fn sqlserver_value_to_json(value: &ColumnData<'_>) -> Value {
    match value {
        ColumnData::U8(Some(value)) => json!(value),
        ColumnData::I16(Some(value)) => json!(value),
        ColumnData::I32(Some(value)) => json!(value),
        ColumnData::I64(Some(value)) => json!(value),
        ColumnData::F32(Some(value)) => json!(value),
        ColumnData::F64(Some(value)) => json!(value),
        ColumnData::Bit(Some(value)) => json!(value),
        ColumnData::String(Some(value)) => json!(value.to_string()),
        ColumnData::Guid(Some(value)) => json!(value.to_string()),
        ColumnData::Binary(Some(value)) => json!(format!("<blob:{}>", value.len())),
        ColumnData::Numeric(Some(value)) => json!(value.to_string()),
        ColumnData::Xml(Some(value)) => json!(value.to_string()),
        ColumnData::DateTime(Some(value)) => json!(format!("{value:?}")),
        ColumnData::SmallDateTime(Some(value)) => json!(format!("{value:?}")),
        ColumnData::Time(Some(value)) => json!(format!("{value:?}")),
        ColumnData::Date(Some(value)) => json!(format!("{value:?}")),
        ColumnData::DateTime2(Some(value)) => json!(format!("{value:?}")),
        ColumnData::DateTimeOffset(Some(value)) => json!(format!("{value:?}")),
        _ => Value::Null,
    }
}

fn json_to_tiberius_param(
    value: &Value,
    data_type: &str,
    nullable: bool,
) -> Result<Box<dyn ToSql>> {
    let normalized = normalize_json_value(value, data_type, nullable)?;
    Ok(match normalized {
        Value::Null => Box::new(Option::<String>::None),
        Value::Bool(value) => Box::new(value),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                Box::new(integer)
            } else {
                Box::new(
                    number
                        .as_f64()
                        .ok_or_else(|| anyhow::anyhow!("invalid numeric value"))?,
                )
            }
        }
        Value::String(value) => Box::new(value),
        other => Box::new(serde_json::to_string(&other)?),
    })
}
