use std::collections::BTreeMap;
use std::io::{self, Read};

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use mysql::prelude::Queryable;
use postgres::{Client, NoTls, SimpleQueryMessage};
use regex::Regex;
use rusqlite::types::{Value as SqliteValue, ValueRef};
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
    UpdateRow,
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

#[derive(Debug, Deserialize)]
struct ColumnUpdateInput {
    name: String,
    data_type: String,
    nullable: bool,
}

#[derive(Debug, Deserialize)]
struct KeyFieldInput {
    name: String,
    data_type: String,
    nullable: bool,
    value: Value,
}

#[derive(Debug, Deserialize)]
struct UpdateRowRequest {
    connection: ConnectionInput,
    table: String,
    schema: Option<String>,
    column: ColumnUpdateInput,
    keys: Vec<KeyFieldInput>,
    new_value_text: String,
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
    primary_key: bool,
}

#[derive(Debug, Serialize)]
struct ListDatabasesResponse {
    current: String,
    available: Vec<String>,
}

#[derive(Debug, Serialize)]
struct UpdateRowResponse {
    affected_rows: u64,
    value: Value,
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
        Command::UpdateRow => {
            let request: UpdateRowRequest = read_stdin_json()?;
            print_json(&update_row(
                request.connection,
                request.table,
                request.schema,
                request.column,
                request.keys,
                request.new_value_text,
            )?)?;
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

fn update_row(
    connection: ConnectionInput,
    table: String,
    schema: Option<String>,
    column: ColumnUpdateInput,
    keys: Vec<KeyFieldInput>,
    new_value_text: String,
) -> Result<UpdateRowResponse> {
    if keys.is_empty() {
        bail!("update keys are required");
    }

    let url = effective_url(&connection)?;
    let value = parse_text_value(&new_value_text, &column.data_type, column.nullable)?;
    let affected_rows = match normalize_kind(&connection.kind)? {
        DriverKind::Sqlite => update_row_sqlite(&url, &table, schema.as_deref(), &column, &keys, &value)?,
        DriverKind::Postgres => update_row_postgres(&url, &table, schema.as_deref(), &column, &keys, &value)?,
        DriverKind::Mysql => update_row_mysql(&url, &table, schema.as_deref(), &column, &keys, &value)?,
    };
    Ok(UpdateRowResponse { affected_rows, value })
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
                primary_key: row.get::<_, i64>(5)? > 0,
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
        select
            c.column_name,
            c.data_type,
            c.is_nullable,
            c.column_default,
            c.ordinal_position,
            exists (
              select 1
              from information_schema.table_constraints tc
              join information_schema.key_column_usage kcu
                on tc.constraint_name = kcu.constraint_name
               and tc.table_schema = kcu.table_schema
             where tc.constraint_type = 'PRIMARY KEY'
               and tc.table_schema = c.table_schema
               and tc.table_name = c.table_name
               and kcu.column_name = c.column_name
            ) as primary_key
        from information_schema.columns c
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
            primary_key: row.get::<_, bool>(5),
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
        select column_name, data_type, is_nullable, column_default, ordinal_position, column_key
        from information_schema.columns
        where table_schema = ? and table_name = ?
        order by ordinal_position
    ";
    let rows: Vec<(String, String, String, Option<String>, i64, String)> = conn.exec(query, (schema, table))?;
    Ok(rows
        .into_iter()
        .map(|(name, data_type, is_nullable, default_value, ordinal_position, column_key)| ColumnInfo {
            name,
            data_type,
            nullable: is_nullable == "YES",
            default_value,
            ordinal_position,
            primary_key: column_key == "PRI",
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

fn quote_identifier(kind: DriverKind, value: &str) -> String {
    match kind {
        DriverKind::Mysql => format!("`{}`", value.replace('`', "``")),
        DriverKind::Sqlite | DriverKind::Postgres => format!("\"{}\"", value.replace('"', "\"\"")),
    }
}

fn qualify_table_name(kind: DriverKind, schema: Option<&str>, table: &str) -> String {
    match schema.filter(|value| !value.is_empty()) {
        Some(schema_name) => format!("{}.{}", quote_identifier(kind, schema_name), quote_identifier(kind, table)),
        None => quote_identifier(kind, table),
    }
}

fn is_boolean_type(data_type: &str) -> bool {
    data_type.contains("bool")
}

fn is_integer_type(data_type: &str) -> bool {
    data_type.contains("int") || data_type == "serial" || data_type == "bigserial"
}

fn is_float_type(data_type: &str) -> bool {
    data_type.contains("numeric")
        || data_type.contains("decimal")
        || data_type.contains("real")
        || data_type.contains("double")
        || data_type.contains("float")
}

fn parse_text_value(text: &str, data_type: &str, nullable: bool) -> Result<Value> {
    normalize_json_value(&Value::String(text.to_string()), data_type, nullable)
}

fn normalize_json_value(value: &Value, data_type: &str, nullable: bool) -> Result<Value> {
    if value.is_null() {
        if nullable {
            return Ok(Value::Null);
        }
        bail!("column is not nullable");
    }

    let lowered = data_type.to_ascii_lowercase();
    if let Some(text) = value.as_str() {
        if nullable && text.trim().eq_ignore_ascii_case("null") {
            return Ok(Value::Null);
        }
        if is_boolean_type(&lowered) {
            let parsed = match text.trim().to_ascii_lowercase().as_str() {
                "true" | "t" | "1" => true,
                "false" | "f" | "0" => false,
                _ => bail!("expected a boolean value"),
            };
            return Ok(Value::Bool(parsed));
        }
        if is_integer_type(&lowered) {
            return Ok(json!(text.trim().parse::<i64>().context("expected an integer value")?));
        }
        if is_float_type(&lowered) {
            let parsed = text.trim().parse::<f64>().context("expected a numeric value")?;
            let number = serde_json::Number::from_f64(parsed).ok_or_else(|| anyhow!("expected a finite numeric value"))?;
            return Ok(Value::Number(number));
        }
        return Ok(Value::String(text.to_string()));
    }

    if is_boolean_type(&lowered) {
        if let Some(boolean) = value.as_bool() {
            return Ok(Value::Bool(boolean));
        }
    }

    if is_integer_type(&lowered) {
        if let Some(integer) = value.as_i64() {
            return Ok(json!(integer));
        }
        if let Some(unsigned) = value.as_u64() {
            return Ok(json!(i64::try_from(unsigned).context("unsigned integer is too large")?));
        }
    }

    if is_float_type(&lowered) {
        if let Some(number) = value.as_f64() {
            let number = serde_json::Number::from_f64(number).ok_or_else(|| anyhow!("expected a finite numeric value"))?;
            return Ok(Value::Number(number));
        }
    }

    Ok(value.clone())
}

fn json_to_sqlite_value(value: &Value) -> Result<SqliteValue> {
    Ok(match value {
        Value::Null => SqliteValue::Null,
        Value::Bool(boolean) => SqliteValue::Integer(if *boolean { 1 } else { 0 }),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                SqliteValue::Integer(integer)
            } else {
                SqliteValue::Real(number.as_f64().ok_or_else(|| anyhow!("invalid numeric value"))?)
            }
        }
        Value::String(text) => SqliteValue::Text(text.clone()),
        other => SqliteValue::Text(serde_json::to_string(other)?),
    })
}

fn json_to_postgres_param(value: &Value) -> Result<Box<dyn postgres::types::ToSql + Sync>> {
    Ok(match value {
        Value::Null => Box::new(Option::<String>::None),
        Value::Bool(boolean) => Box::new(*boolean),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                Box::new(integer)
            } else {
                Box::new(number.as_f64().ok_or_else(|| anyhow!("invalid numeric value"))?)
            }
        }
        Value::String(text) => Box::new(text.clone()),
        other => Box::new(serde_json::to_string(other)?),
    })
}

fn json_to_mysql_value(value: &Value) -> Result<mysql::Value> {
    Ok(match value {
        Value::Null => mysql::Value::NULL,
        Value::Bool(boolean) => mysql::Value::Int(if *boolean { 1 } else { 0 }),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                mysql::Value::Int(integer)
            } else if let Some(unsigned) = number.as_u64() {
                mysql::Value::UInt(unsigned)
            } else {
                mysql::Value::Double(number.as_f64().ok_or_else(|| anyhow!("invalid numeric value"))?)
            }
        }
        Value::String(text) => mysql::Value::Bytes(text.as_bytes().to_vec()),
        other => mysql::Value::Bytes(serde_json::to_string(other)?.into_bytes()),
    })
}

fn normalized_key_values(keys: &[KeyFieldInput]) -> Result<Vec<(String, String, Value)>> {
    keys.iter()
        .map(|key| {
            Ok((
                key.name.clone(),
                key.data_type.clone(),
                normalize_json_value(&key.value, &key.data_type, key.nullable)?,
            ))
        })
        .collect()
}

fn update_row_sqlite(
    url: &str,
    table: &str,
    schema: Option<&str>,
    column: &ColumnUpdateInput,
    keys: &[KeyFieldInput],
    value: &Value,
) -> Result<u64> {
    let conn = rusqlite::Connection::open(sqlite_path(url)).context("failed to open sqlite database")?;
    let mut params = vec![json_to_sqlite_value(value)?];
    let mut clauses = Vec::new();

    for (name, _, key_value) in normalized_key_values(keys)? {
        if key_value.is_null() {
            clauses.push(format!("{} IS NULL", quote_identifier(DriverKind::Sqlite, &name)));
        } else {
            clauses.push(format!(
                "{} = ?{}",
                quote_identifier(DriverKind::Sqlite, &name),
                params.len() + 1
            ));
            params.push(json_to_sqlite_value(&key_value)?);
        }
    }

    let query = format!(
        "UPDATE {} SET {} = ?1 WHERE {}",
        qualify_table_name(DriverKind::Sqlite, schema, table),
        quote_identifier(DriverKind::Sqlite, &column.name),
        clauses.join(" AND ")
    );
    Ok(conn.execute(&query, rusqlite::params_from_iter(params))? as u64)
}

fn update_row_postgres(
    url: &str,
    table: &str,
    schema: Option<&str>,
    column: &ColumnUpdateInput,
    keys: &[KeyFieldInput],
    value: &Value,
) -> Result<u64> {
    let mut client = Client::connect(url, NoTls).context("failed to connect to postgres")?;
    let mut params = vec![json_to_postgres_param(value)?];
    let mut clauses = Vec::new();

    for (name, _, key_value) in normalized_key_values(keys)? {
        if key_value.is_null() {
            clauses.push(format!("{} IS NULL", quote_identifier(DriverKind::Postgres, &name)));
        } else {
            let param_index = params.len() + 1;
            clauses.push(format!(
                "{} = ${}",
                quote_identifier(DriverKind::Postgres, &name),
                param_index
            ));
            params.push(json_to_postgres_param(&key_value)?);
        }
    }

    let query = format!(
        "UPDATE {} SET {} = $1 WHERE {}",
        qualify_table_name(DriverKind::Postgres, schema, table),
        quote_identifier(DriverKind::Postgres, &column.name),
        clauses.join(" AND ")
    );
    let param_refs = params.iter().map(|value| value.as_ref()).collect::<Vec<_>>();
    Ok(client.execute(&query, &param_refs)?)
}

fn update_row_mysql(
    url: &str,
    table: &str,
    schema: Option<&str>,
    column: &ColumnUpdateInput,
    keys: &[KeyFieldInput],
    value: &Value,
) -> Result<u64> {
    let opts = mysql::Opts::from_url(url).context("failed to parse mysql connection URL")?;
    let pool = mysql::Pool::new(opts)?;
    let mut conn = pool.get_conn()?;
    let mut params = vec![json_to_mysql_value(value)?];
    let mut clauses = Vec::new();

    for (name, _, key_value) in normalized_key_values(keys)? {
        if key_value.is_null() {
            clauses.push(format!("{} IS NULL", quote_identifier(DriverKind::Mysql, &name)));
        } else {
            clauses.push(format!("{} = ?", quote_identifier(DriverKind::Mysql, &name)));
            params.push(json_to_mysql_value(&key_value)?);
        }
    }

    let query = format!(
        "UPDATE {} SET {} = ? WHERE {}",
        qualify_table_name(DriverKind::Mysql, schema, table),
        quote_identifier(DriverKind::Mysql, &column.name),
        clauses.join(" AND ")
    );
    conn.exec_drop(query, mysql::Params::Positional(params))?;
    Ok(conn.affected_rows())
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
