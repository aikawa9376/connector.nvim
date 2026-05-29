use std::collections::BTreeMap;
use std::io::{self, Read};

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use mysql::prelude::Queryable;
use postgres::{Client, NoTls, SimpleQueryMessage};
use regex::Regex;
use rusqlite::types::ValueRef;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use url::Url;

#[derive(Parser)]
#[command(author, version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Execute,
    Structure,
    Columns,
    ListDatabases,
}

#[derive(Debug, Clone, Deserialize)]
struct ConnectionInput {
    name: Option<String>,
    #[serde(rename = "type")]
    kind: String,
    url: String,
    database: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ExecuteRequest {
    connection: ConnectionInput,
    query: String,
}

#[derive(Debug, Deserialize)]
struct ColumnsRequest {
    connection: ConnectionInput,
    table: String,
    schema: Option<String>,
    materialization: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ConnectionRequest {
    connection: ConnectionInput,
}

#[derive(Debug, Serialize)]
struct ColumnMeta {
    name: String,
}

#[derive(Debug, Serialize)]
struct ExecuteResponse {
    columns: Vec<ColumnMeta>,
    rows: Vec<Vec<Value>>,
    row_count: usize,
    message: Option<String>,
}

#[derive(Debug, Serialize)]
struct StructureItem {
    schema: Option<String>,
    name: String,
    materialization: String,
}

#[derive(Debug, Serialize)]
struct ColumnInfo {
    name: String,
    data_type: String,
    nullable: bool,
    default_value: Option<String>,
    ordinal_position: i64,
}

#[derive(Debug, Serialize)]
struct ListDatabasesResponse {
    current: String,
    available: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DriverKind {
    Sqlite,
    Postgres,
    Mysql,
}

fn main() {
    if let Err(err) = run() {
        let payload = json!({ "error": format!("{err:#}") });
        println!("{}", serde_json::to_string(&payload).unwrap_or_else(|_| "{\"error\":\"unknown error\"}".to_string()));
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Execute => {
            let request: ExecuteRequest = read_stdin_json()?;
            print_json(&execute(request.connection, request.query)?)?;
        }
        Command::Structure => {
            let request: ConnectionRequest = read_stdin_json()?;
            print_json(&structure(request.connection)?)?;
        }
        Command::Columns => {
            let request: ColumnsRequest = read_stdin_json()?;
            print_json(&columns(
                request.connection,
                request.table,
                request.schema,
                request.materialization,
            )?)?;
        }
        Command::ListDatabases => {
            let request: ConnectionRequest = read_stdin_json()?;
            print_json(&list_databases(request.connection)?)?;
        }
    }

    Ok(())
}

fn read_stdin_json<T: for<'de> Deserialize<'de>>() -> Result<T> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    serde_json::from_str(&input).context("failed to decode request JSON")
}

fn print_json<T: Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string(value)?);
    Ok(())
}

fn normalize_kind(kind: &str) -> Result<DriverKind> {
    match kind.to_ascii_lowercase().as_str() {
        "sqlite" | "sqlite3" => Ok(DriverKind::Sqlite),
        "postgres" | "postgresql" | "pg" => Ok(DriverKind::Postgres),
        "mysql" | "mariadb" => Ok(DriverKind::Mysql),
        other => bail!("unsupported connection type: {other}"),
    }
}

fn effective_url(connection: &ConnectionInput) -> Result<String> {
    let mut url = expand_template(&connection.url)?;
    if let Some(database) = connection.database.as_ref().filter(|value| !value.is_empty()) {
        url = apply_database_override(&url, &connection.kind, database)?;
    }
    Ok(url)
}

fn expand_template(input: &str) -> Result<String> {
    let pattern = Regex::new(r#"\{\{\s*(env|exec)\s+((?:"[^"]*")|(?:`[^`]*`))\s*\}\}"#)?;
    let mut output = String::new();
    let mut last = 0usize;
    for capture in pattern.captures_iter(input) {
        let matched = capture.get(0).unwrap();
        output.push_str(&input[last..matched.start()]);
        let mode = capture.get(1).unwrap().as_str();
        let raw = capture.get(2).unwrap().as_str();
        let arg = raw.trim_matches('"').trim_matches('`');
        let replacement = match mode {
            "env" => std::env::var(arg).unwrap_or_default(),
            "exec" => shell_exec(arg)?,
            _ => String::new(),
        };
        output.push_str(&replacement);
        last = matched.end();
    }
    output.push_str(&input[last..]);
    Ok(output)
}

#[cfg(target_os = "windows")]
fn shell_exec(command: &str) -> Result<String> {
    let output = std::process::Command::new("cmd")
        .args(["/C", command])
        .output()
        .with_context(|| format!("failed to execute command: {command}"))?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(not(target_os = "windows"))]
fn shell_exec(command: &str) -> Result<String> {
    let output = std::process::Command::new("sh")
        .args(["-lc", command])
        .output()
        .with_context(|| format!("failed to execute command: {command}"))?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn apply_database_override(raw_url: &str, kind: &str, database: &str) -> Result<String> {
    let driver = normalize_kind(kind)?;
    if driver == DriverKind::Sqlite {
        return Ok(raw_url.to_string());
    }

    let mut parsed = Url::parse(raw_url).with_context(|| format!("expected URL connection string: {raw_url}"))?;
    parsed.set_path(&format!("/{database}"));
    Ok(parsed.to_string())
}

fn execute(connection: ConnectionInput, query: String) -> Result<ExecuteResponse> {
    let url = effective_url(&connection)?;
    match normalize_kind(&connection.kind)? {
        DriverKind::Sqlite => execute_sqlite(&url, &query),
        DriverKind::Postgres => execute_postgres(&url, &query),
        DriverKind::Mysql => execute_mysql(&url, &query),
    }
}

fn structure(connection: ConnectionInput) -> Result<Vec<StructureItem>> {
    let url = effective_url(&connection)?;
    match normalize_kind(&connection.kind)? {
        DriverKind::Sqlite => structure_sqlite(&url),
        DriverKind::Postgres => structure_postgres(&url),
        DriverKind::Mysql => structure_mysql(&url),
    }
}

fn columns(
    connection: ConnectionInput,
    table: String,
    schema: Option<String>,
    _materialization: Option<String>,
) -> Result<Vec<ColumnInfo>> {
    let url = effective_url(&connection)?;
    match normalize_kind(&connection.kind)? {
        DriverKind::Sqlite => columns_sqlite(&url, &table),
        DriverKind::Postgres => columns_postgres(&url, &table, schema),
        DriverKind::Mysql => columns_mysql(&url, &table, schema),
    }
}

fn list_databases(connection: ConnectionInput) -> Result<ListDatabasesResponse> {
    let url = effective_url(&connection)?;
    match normalize_kind(&connection.kind)? {
        DriverKind::Sqlite => {
            let current = connection
                .database
                .or_else(|| connection.name.clone())
                .unwrap_or_else(|| url.clone());
            Ok(ListDatabasesResponse {
                current,
                available: Vec::new(),
            })
        }
        DriverKind::Postgres => list_databases_postgres(&url),
        DriverKind::Mysql => list_databases_mysql(&url),
    }
}

fn execute_sqlite(url: &str, query: &str) -> Result<ExecuteResponse> {
    let path = sqlite_path(url);
    let conn = rusqlite::Connection::open(path).context("failed to open sqlite database")?;
    let trimmed = query.trim().trim_end_matches(';').trim();
    if trimmed.is_empty() {
        bail!("query is empty");
    }

    if starts_with_row_query(trimmed) {
        let mut stmt = conn.prepare(trimmed)?;
        let columns = stmt
            .column_names()
            .iter()
            .map(|name| ColumnMeta {
                name: (*name).to_string(),
            })
            .collect::<Vec<_>>();
        let mut rows = Vec::new();
        let mut result_rows = stmt.query([])?;
        while let Some(row) = result_rows.next()? {
            let mut values = Vec::new();
            for index in 0..columns.len() {
                let value = match row.get_ref(index)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(v) => json!(v),
                    ValueRef::Real(v) => json!(v),
                    ValueRef::Text(v) => json!(String::from_utf8_lossy(v).to_string()),
                    ValueRef::Blob(v) => json!(format!("<blob:{}>", v.len())),
                };
                values.push(value);
            }
            rows.push(values);
        }
        Ok(ExecuteResponse {
            row_count: rows.len(),
            columns,
            rows,
            message: None,
        })
    } else {
        conn.execute_batch(trimmed)?;
        Ok(ExecuteResponse {
            columns: vec![ColumnMeta {
                name: "status".to_string(),
            }],
            rows: vec![vec![json!("ok")]],
            row_count: 1,
            message: Some("statement executed".to_string()),
        })
    }
}

fn structure_sqlite(url: &str) -> Result<Vec<StructureItem>> {
    let path = sqlite_path(url);
    let conn = rusqlite::Connection::open(path)?;
    let mut stmt = conn.prepare(
        "select name, type from sqlite_master where type in ('table', 'view') and name not like 'sqlite_%' order by name",
    )?;
    let items = stmt
        .query_map([], |row| {
            Ok(StructureItem {
                schema: Some("main".to_string()),
                name: row.get::<_, String>(0)?,
                materialization: row.get::<_, String>(1)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(items)
}

fn columns_sqlite(url: &str, table: &str) -> Result<Vec<ColumnInfo>> {
    let path = sqlite_path(url);
    let conn = rusqlite::Connection::open(path)?;
    let mut stmt = conn.prepare(&format!("pragma table_info({})", quote_sqlite_identifier(table)))?;
    let columns = stmt
        .query_map([], |row| {
            Ok(ColumnInfo {
                ordinal_position: row.get::<_, i64>(0)?,
                name: row.get::<_, String>(1)?,
                data_type: row.get::<_, String>(2)?,
                nullable: row.get::<_, i64>(3)? == 0,
                default_value: row.get::<_, Option<String>>(4)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(columns)
}

fn execute_postgres(url: &str, query: &str) -> Result<ExecuteResponse> {
    let mut client = Client::connect(url, NoTls).context("failed to connect to postgres")?;
    let messages = client.simple_query(query)?;
    let mut columns = Vec::new();
    let mut rows = Vec::new();

    for message in messages {
        match message {
            SimpleQueryMessage::Row(row) => {
                if columns.is_empty() {
                    columns = row
                        .columns()
                        .iter()
                        .map(|column| ColumnMeta {
                            name: column.name().to_string(),
                        })
                        .collect();
                }
                let mut values = Vec::new();
                for index in 0..row.len() {
                    values.push(match row.get(index) {
                        Some(value) => json!(value),
                        None => Value::Null,
                    });
                }
                rows.push(values);
            }
            SimpleQueryMessage::CommandComplete(count) => {
                if columns.is_empty() && rows.is_empty() {
                    columns = vec![ColumnMeta {
                        name: "affected_rows".to_string(),
                    }];
                    rows.push(vec![json!(count)]);
                }
            }
            _ => {}
        }
    }

    if columns.is_empty() {
        columns = vec![ColumnMeta {
            name: "status".to_string(),
        }];
        rows.push(vec![json!("ok")]);
    }

    Ok(ExecuteResponse {
        row_count: rows.len(),
        columns,
        rows,
        message: None,
    })
}

fn structure_postgres(url: &str) -> Result<Vec<StructureItem>> {
    let mut client = Client::connect(url, NoTls)?;
    let query = "
        select table_schema, table_name, 'table' as materialization
        from information_schema.tables
        where table_schema not in ('pg_catalog', 'information_schema')
        union all
        select schemaname, matviewname, 'materialized_view'
        from pg_matviews
        order by 1, 2
    ";
    let rows = client.query(query, &[])?;
    let items = rows
        .into_iter()
        .map(|row| StructureItem {
            schema: Some(row.get::<_, String>(0)),
            name: row.get::<_, String>(1),
            materialization: row.get::<_, String>(2),
        })
        .collect();
    Ok(items)
}

fn columns_postgres(url: &str, table: &str, schema: Option<String>) -> Result<Vec<ColumnInfo>> {
    let mut client = Client::connect(url, NoTls)?;
    let schema = schema.unwrap_or_else(|| "public".to_string());
    let query = "
        select column_name, data_type, is_nullable, column_default, ordinal_position
        from information_schema.columns
        where table_schema = $1 and table_name = $2
        order by ordinal_position
    ";
    let rows = client.query(query, &[&schema, &table])?;
    let columns = rows
        .into_iter()
        .map(|row| ColumnInfo {
            name: row.get::<_, String>(0),
            data_type: row.get::<_, String>(1),
            nullable: row.get::<_, String>(2) == "YES",
            default_value: row.get::<_, Option<String>>(3),
            ordinal_position: row.get::<_, i32>(4) as i64,
        })
        .collect();
    Ok(columns)
}

fn list_databases_postgres(url: &str) -> Result<ListDatabasesResponse> {
    let mut client = Client::connect(url, NoTls)?;
    let current = client
        .query_one("select current_database()", &[])?
        .get::<_, String>(0);
    let available = client
        .query("select datname from pg_database where datistemplate = false order by datname", &[])?
        .into_iter()
        .map(|row| row.get::<_, String>(0))
        .collect();
    Ok(ListDatabasesResponse { current, available })
}

fn execute_mysql(url: &str, query: &str) -> Result<ExecuteResponse> {
    let opts = mysql::Opts::from_url(url).context("failed to parse mysql connection URL")?;
    let pool = mysql::Pool::new(opts)?;
    let mut conn = pool.get_conn()?;
    let mut result = conn.query_iter(query)?;

    let columns = result
        .columns()
        .as_ref()
        .iter()
        .map(|column| ColumnMeta {
            name: column.name_str().to_string(),
        })
        .collect::<Vec<_>>();

    let mut rows = Vec::new();
    while let Some(row) = result.next() {
        let row = row?;
        let values = row
            .unwrap()
            .into_iter()
            .map(mysql_value_to_json)
            .collect::<Vec<_>>();
        rows.push(values);
    }

    if columns.is_empty() {
        let affected_rows = result.affected_rows();
        drop(result);
        return Ok(ExecuteResponse {
            columns: vec![ColumnMeta {
                name: "affected_rows".to_string(),
            }],
            rows: vec![vec![json!(affected_rows)]],
            row_count: 1,
            message: None,
        });
    }

    Ok(ExecuteResponse {
        row_count: rows.len(),
        columns,
        rows,
        message: None,
    })
}

fn structure_mysql(url: &str) -> Result<Vec<StructureItem>> {
    let opts = mysql::Opts::from_url(url)?;
    let pool = mysql::Pool::new(opts)?;
    let mut conn = pool.get_conn()?;
    let query = "
        select table_schema, table_name,
          case
            when table_type = 'VIEW' then 'view'
            else 'table'
          end as materialization
        from information_schema.tables
        where table_schema = database()
        order by table_schema, table_name
    ";
    let rows: Vec<(String, String, String)> = conn.query(query)?;
    Ok(rows
        .into_iter()
        .map(|(schema, name, materialization)| StructureItem {
            schema: Some(schema),
            name,
            materialization,
        })
        .collect())
}

fn columns_mysql(url: &str, table: &str, schema: Option<String>) -> Result<Vec<ColumnInfo>> {
    let opts = mysql::Opts::from_url(url)?;
    let pool = mysql::Pool::new(opts)?;
    let mut conn = pool.get_conn()?;
    let schema = match schema {
        Some(value) => value,
        None => conn
            .query_first::<String, _>("select database()")?
            .ok_or_else(|| anyhow!("failed to determine current database"))?,
    };
    let query = "
        select column_name, data_type, is_nullable, column_default, ordinal_position
        from information_schema.columns
        where table_schema = ? and table_name = ?
        order by ordinal_position
    ";
    let rows: Vec<(String, String, String, Option<String>, i64)> = conn.exec(query, (schema, table))?;
    Ok(rows
        .into_iter()
        .map(|(name, data_type, is_nullable, default_value, ordinal_position)| ColumnInfo {
            name,
            data_type,
            nullable: is_nullable == "YES",
            default_value,
            ordinal_position,
        })
        .collect())
}

fn list_databases_mysql(url: &str) -> Result<ListDatabasesResponse> {
    let opts = mysql::Opts::from_url(url)?;
    let pool = mysql::Pool::new(opts)?;
    let mut conn = pool.get_conn()?;
    let current = conn
        .query_first::<String, _>("select database()")?
        .unwrap_or_default();
    let available: Vec<String> = conn.query("show databases")?;
    Ok(ListDatabasesResponse { current, available })
}

fn mysql_value_to_json(value: mysql::Value) -> Value {
    match value {
        mysql::Value::NULL => Value::Null,
        mysql::Value::Bytes(bytes) => match String::from_utf8(bytes.clone()) {
            Ok(text) => json!(text),
            Err(_) => json!(format!("<blob:{}>", bytes.len())),
        },
        mysql::Value::Int(value) => json!(value),
        mysql::Value::UInt(value) => json!(value),
        mysql::Value::Float(value) => json!(value),
        mysql::Value::Double(value) => json!(value),
        mysql::Value::Date(year, month, day, hour, minute, second, micros) => json!(format!(
            "{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}.{:06}",
            micros
        )),
        mysql::Value::Time(neg, days, hours, minutes, seconds, micros) => {
            let sign = if neg { "-" } else { "" };
            json!(format!(
                "{sign}{days} {:02}:{:02}:{:02}.{:06}",
                hours, minutes, seconds, micros
            ))
        }
    }
}

fn sqlite_path(url: &str) -> String {
    let trimmed = url.trim();
    if let Some(stripped) = trimmed.strip_prefix("sqlite://") {
        stripped.to_string()
    } else if let Some(stripped) = trimmed.strip_prefix("file:") {
        stripped.to_string()
    } else {
        trimmed.to_string()
    }
}

fn quote_sqlite_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn starts_with_row_query(query: &str) -> bool {
    let first = query
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        first.as_str(),
        "select" | "with" | "pragma" | "show" | "describe" | "desc" | "explain"
    )
}

#[allow(dead_code)]
fn grouped_structure(items: &[StructureItem]) -> BTreeMap<String, Vec<StructureItem>> {
    let mut map = BTreeMap::new();
    for item in items {
        let schema = item.schema.clone().unwrap_or_default();
        map.entry(schema).or_insert_with(Vec::new).push(StructureItem {
            schema: item.schema.clone(),
            name: item.name.clone(),
            materialization: item.materialization.clone(),
        });
    }
    map
}
