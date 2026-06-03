use anyhow::{bail, Context, Result};
use rusqlite::types::ValueRef;
use serde_json::{json, Value};

use crate::driver::{Driver, DriverKind};
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};
use crate::sql::{
    qualify_table_name, quote_identifier, quote_sqlite_identifier, sqlite_path,
    starts_with_row_query,
};
use crate::value::{json_to_sqlite_value, normalized_key_values};

pub struct SqliteDriver;

impl Driver for SqliteDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
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

    fn structure(&self, url: &str) -> Result<Vec<StructureItem>> {
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

    fn columns(
        &self,
        url: &str,
        table: &str,
        _schema: Option<String>,
        _materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>> {
        let path = sqlite_path(url);
        let conn = rusqlite::Connection::open(path)?;
        let mut stmt = conn.prepare(&format!(
            "pragma table_info({})",
            quote_sqlite_identifier(table)
        ))?;
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

    fn list_databases(
        &self,
        url: &str,
        connection: &ConnectionInput,
    ) -> Result<ListDatabasesResponse> {
        let current = connection
            .database
            .clone()
            .or_else(|| connection.name.clone())
            .unwrap_or_else(|| url.to_string());
        Ok(ListDatabasesResponse {
            current,
            available: Vec::new(),
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
        let conn = rusqlite::Connection::open(sqlite_path(url))
            .context("failed to open sqlite database")?;
        let mut params = vec![json_to_sqlite_value(value)?];
        let mut clauses = Vec::new();

        for (name, _, key_value) in normalized_key_values(keys)? {
            if key_value.is_null() {
                clauses.push(format!(
                    "{} IS NULL",
                    quote_identifier(DriverKind::Sqlite, &name)
                ));
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
}
