use anyhow::{bail, Context, Result};
use serde_json::{json, Map, Value};
use url::Url;

use crate::driver::Driver;
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};

pub struct RedisDriver;

impl Driver for RedisDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
        let args = parse_redis_command(query.trim())?;
        let client = redis::Client::open(url).context("failed to create redis client")?;
        let mut connection = client
            .get_connection()
            .context("failed to connect to redis")?;

        let mut command = redis::cmd(&args[0]);
        for arg in &args[1..] {
            command.arg(arg);
        }

        let value: redis::Value = command.query(&mut connection)?;
        let rows = redis_value_to_rows(value);
        Ok(ExecuteResponse {
            columns: vec![ColumnMeta {
                name: "Reply".to_string(),
            }],
            row_count: rows.len(),
            rows,
            message: None,
        })
    }

    fn structure(&self, _url: &str) -> Result<Vec<StructureItem>> {
        Ok(vec![StructureItem {
            schema: None,
            name: "Storage".to_string(),
            materialization: "table".to_string(),
        }])
    }

    fn columns(
        &self,
        _url: &str,
        _table: &str,
        _schema: Option<String>,
        _materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>> {
        Ok(vec![ColumnInfo {
            name: "Reply".to_string(),
            data_type: "redis".to_string(),
            nullable: true,
            default_value: None,
            ordinal_position: 1,
            primary_key: false,
        }])
    }

    fn list_databases(
        &self,
        url: &str,
        _connection: &ConnectionInput,
    ) -> Result<ListDatabasesResponse> {
        let current = redis_database_name(url);
        Ok(ListDatabasesResponse {
            current: current.clone(),
            available: vec![current],
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
        bail!("row updates are not supported for redis")
    }
}

fn parse_redis_command(input: &str) -> Result<Vec<String>> {
    if input.is_empty() {
        bail!("query is empty");
    }

    let mut fields = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut token_started = false;

    for (index, ch) in input.char_indices() {
        if escaped {
            current.push(ch);
            escaped = false;
            token_started = true;
            continue;
        }

        if ch == '\\' {
            escaped = true;
            token_started = true;
            continue;
        }

        if let Some(current_quote) = quote {
            if ch == current_quote {
                quote = None;
            } else {
                current.push(ch);
            }
            token_started = true;
            continue;
        }

        if ch == '"' || ch == '\'' {
            quote = Some(ch);
            token_started = true;
            continue;
        }

        if ch.is_whitespace() {
            if token_started {
                fields.push(std::mem::take(&mut current));
                token_started = false;
            }
            continue;
        }

        current.push(ch);
        token_started = true;

        if index == input.len() - 1 {
            break;
        }
    }

    if escaped {
        current.push('\\');
    }

    if let Some(current_quote) = quote {
        bail!("syntax error: unmatched {current_quote} quote");
    }

    if token_started {
        fields.push(current);
    }

    if fields.is_empty() {
        bail!("query is empty");
    }
    Ok(fields)
}

fn redis_value_to_rows(value: redis::Value) -> Vec<Vec<Value>> {
    match value {
        redis::Value::Array(values) | redis::Value::Set(values) => values
            .into_iter()
            .map(|value| vec![redis_value_to_json(value)])
            .collect(),
        other => vec![vec![redis_value_to_json(other)]],
    }
}

fn redis_value_to_json(value: redis::Value) -> Value {
    match value {
        redis::Value::Nil => Value::Null,
        redis::Value::Int(value) => json!(value),
        redis::Value::BulkString(bytes) => bytes_to_json(bytes),
        redis::Value::Array(values) | redis::Value::Set(values) => {
            Value::Array(values.into_iter().map(redis_value_to_json).collect())
        }
        redis::Value::SimpleString(value) => json!(value),
        redis::Value::Okay => json!("OK"),
        redis::Value::Map(values) => redis_map_to_json(values),
        redis::Value::Attribute { data, attributes } => json!({
            "data": redis_value_to_json(*data),
            "attributes": redis_map_to_json(attributes),
        }),
        redis::Value::Double(value) => json!(value),
        redis::Value::Boolean(value) => json!(value),
        redis::Value::VerbatimString { format, text } => json!({
            "format": format!("{format:?}"),
            "text": text,
        }),
        redis::Value::BigNumber(value) => json!(value.to_string()),
        redis::Value::Push { kind, data } => json!({
            "kind": format!("{kind:?}"),
            "data": Value::Array(data.into_iter().map(redis_value_to_json).collect()),
        }),
        redis::Value::ServerError(error) => json!(error.to_string()),
        other => json!(format!("{other:?}")),
    }
}

fn redis_map_to_json(values: Vec<(redis::Value, redis::Value)>) -> Value {
    let mut object = Map::new();
    for (key, value) in values {
        object.insert(redis_key_to_string(key), redis_value_to_json(value));
    }
    Value::Object(object)
}

fn redis_key_to_string(value: redis::Value) -> String {
    match value {
        redis::Value::BulkString(bytes) => match String::from_utf8(bytes) {
            Ok(text) => text,
            Err(bytes) => format!("<blob:{}>", bytes.into_bytes().len()),
        },
        redis::Value::SimpleString(value) => value,
        redis::Value::Okay => "OK".to_string(),
        redis::Value::Int(value) => value.to_string(),
        redis::Value::Double(value) => value.to_string(),
        redis::Value::Boolean(value) => value.to_string(),
        redis::Value::BigNumber(value) => value.to_string(),
        other => format!("{other:?}"),
    }
}

fn bytes_to_json(bytes: Vec<u8>) -> Value {
    match String::from_utf8(bytes) {
        Ok(text) => json!(text),
        Err(bytes) => json!(format!("<blob:{}>", bytes.into_bytes().len())),
    }
}

fn redis_database_name(raw_url: &str) -> String {
    let Ok(parsed) = Url::parse(raw_url) else {
        return "0".to_string();
    };

    if let Some((_, value)) = parsed
        .query_pairs()
        .find(|(key, _)| key.eq_ignore_ascii_case("db"))
    {
        return value.into_owned();
    }

    let path = parsed.path().trim_matches('/');
    if path.is_empty() {
        "0".to_string()
    } else {
        path.to_string()
    }
}
