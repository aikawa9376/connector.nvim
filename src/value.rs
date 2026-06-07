use anyhow::{anyhow, bail, Context, Result};
use duckdb::types::{TimeUnit as DuckdbTimeUnit, Value as DuckdbValue, ValueRef as DuckdbValueRef};
use rusqlite::types::Value as SqliteValue;
use serde_json::{json, Value};

use crate::protocol::KeyFieldInput;

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

pub fn parse_text_value(text: &str, data_type: &str, nullable: bool) -> Result<Value> {
    normalize_json_value(&Value::String(text.to_string()), data_type, nullable)
}

pub fn normalize_json_value(value: &Value, data_type: &str, nullable: bool) -> Result<Value> {
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
            return Ok(json!(text
                .trim()
                .parse::<i64>()
                .context("expected an integer value")?));
        }
        if is_float_type(&lowered) {
            let parsed = text
                .trim()
                .parse::<f64>()
                .context("expected a numeric value")?;
            let number = serde_json::Number::from_f64(parsed)
                .ok_or_else(|| anyhow!("expected a finite numeric value"))?;
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
            return Ok(json!(
                i64::try_from(unsigned).context("unsigned integer is too large")?
            ));
        }
    }

    if is_float_type(&lowered) {
        if let Some(number) = value.as_f64() {
            let number = serde_json::Number::from_f64(number)
                .ok_or_else(|| anyhow!("expected a finite numeric value"))?;
            return Ok(Value::Number(number));
        }
    }

    Ok(value.clone())
}

pub fn json_to_sqlite_value(value: &Value) -> Result<SqliteValue> {
    Ok(match value {
        Value::Null => SqliteValue::Null,
        Value::Bool(boolean) => SqliteValue::Integer(if *boolean { 1 } else { 0 }),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                SqliteValue::Integer(integer)
            } else {
                SqliteValue::Real(
                    number
                        .as_f64()
                        .ok_or_else(|| anyhow!("invalid numeric value"))?,
                )
            }
        }
        Value::String(text) => SqliteValue::Text(text.clone()),
        other => SqliteValue::Text(serde_json::to_string(other)?),
    })
}

pub fn json_to_postgres_param(value: &Value) -> Result<Box<dyn postgres::types::ToSql + Sync>> {
    Ok(match value {
        Value::Null => Box::new(Option::<String>::None),
        Value::Bool(boolean) => Box::new(*boolean),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                Box::new(integer)
            } else {
                Box::new(
                    number
                        .as_f64()
                        .ok_or_else(|| anyhow!("invalid numeric value"))?,
                )
            }
        }
        Value::String(text) => Box::new(text.clone()),
        other => Box::new(serde_json::to_string(other)?),
    })
}

pub fn json_to_mysql_value(value: &Value) -> Result<mysql::Value> {
    Ok(match value {
        Value::Null => mysql::Value::NULL,
        Value::Bool(boolean) => mysql::Value::Int(if *boolean { 1 } else { 0 }),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                mysql::Value::Int(integer)
            } else if let Some(unsigned) = number.as_u64() {
                mysql::Value::UInt(unsigned)
            } else {
                mysql::Value::Double(
                    number
                        .as_f64()
                        .ok_or_else(|| anyhow!("invalid numeric value"))?,
                )
            }
        }
        Value::String(text) => mysql::Value::Bytes(text.as_bytes().to_vec()),
        other => mysql::Value::Bytes(serde_json::to_string(other)?.into_bytes()),
    })
}

pub fn json_to_duckdb_value(value: &Value) -> Result<DuckdbValue> {
    Ok(match value {
        Value::Null => DuckdbValue::Null,
        Value::Bool(boolean) => DuckdbValue::Boolean(*boolean),
        Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                DuckdbValue::BigInt(integer)
            } else if let Some(unsigned) = number.as_u64() {
                DuckdbValue::UBigInt(unsigned)
            } else {
                DuckdbValue::Double(
                    number
                        .as_f64()
                        .ok_or_else(|| anyhow!("invalid numeric value"))?,
                )
            }
        }
        Value::String(text) => DuckdbValue::Text(text.clone()),
        other => DuckdbValue::Text(serde_json::to_string(other)?),
    })
}

pub fn normalized_key_values(keys: &[KeyFieldInput]) -> Result<Vec<(String, String, Value)>> {
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

pub fn mysql_value_to_json(value: mysql::Value) -> Value {
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

pub fn duckdb_value_to_json(value: DuckdbValueRef<'_>) -> Value {
    duckdb_owned_value_to_json(value.to_owned())
}

fn duckdb_owned_value_to_json(value: DuckdbValue) -> Value {
    match value {
        DuckdbValue::Null => Value::Null,
        DuckdbValue::Boolean(value) => json!(value),
        DuckdbValue::TinyInt(value) => json!(value),
        DuckdbValue::SmallInt(value) => json!(value),
        DuckdbValue::Int(value) => json!(value),
        DuckdbValue::BigInt(value) => json!(value),
        DuckdbValue::HugeInt(value) => json!(value.to_string()),
        DuckdbValue::UTinyInt(value) => json!(value),
        DuckdbValue::USmallInt(value) => json!(value),
        DuckdbValue::UInt(value) => json!(value),
        DuckdbValue::UBigInt(value) => json!(value),
        DuckdbValue::Float(value) => json!(value),
        DuckdbValue::Double(value) => json!(value),
        DuckdbValue::Decimal(value) => json!(value.to_string()),
        DuckdbValue::Timestamp(unit, value) => json!(format_duckdb_time_value(unit, value)),
        DuckdbValue::Text(value) => json!(value),
        DuckdbValue::Blob(value) => json!(format!("<blob:{}>", value.len())),
        DuckdbValue::Date32(value) => json!(value),
        DuckdbValue::Time64(unit, value) => json!(format_duckdb_time_value(unit, value)),
        DuckdbValue::Interval {
            months,
            days,
            nanos,
        } => json!(format!("{months} months {days} days {nanos} ns")),
        DuckdbValue::List(values) | DuckdbValue::Array(values) => {
            Value::Array(values.into_iter().map(duckdb_owned_value_to_json).collect())
        }
        DuckdbValue::Enum(value) => json!(value),
        DuckdbValue::Struct(values) => {
            let object = values
                .iter()
                .map(|(key, value)| (key.clone(), duckdb_owned_value_to_json(value.clone())))
                .collect();
            Value::Object(object)
        }
        DuckdbValue::Map(values) => Value::Array(
            values
                .iter()
                .map(|(key, value)| {
                    json!({
                        "key": duckdb_owned_value_to_json(key.clone()),
                        "value": duckdb_owned_value_to_json(value.clone()),
                    })
                })
                .collect(),
        ),
        DuckdbValue::Union(value) => duckdb_owned_value_to_json(*value),
    }
}

fn format_duckdb_time_value(unit: DuckdbTimeUnit, value: i64) -> String {
    let suffix = match unit {
        DuckdbTimeUnit::Second => "s",
        DuckdbTimeUnit::Millisecond => "ms",
        DuckdbTimeUnit::Microsecond => "us",
        DuckdbTimeUnit::Nanosecond => "ns",
    };
    format!("{value}{suffix}")
}
