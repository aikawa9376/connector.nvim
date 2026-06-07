use anyhow::{bail, Context, Result};
use duckdb::types::ValueRef;
use serde_json::{json, Value};

use crate::driver::{Driver, DriverKind};
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};
use crate::sql::{duckdb_path, qualify_table_name, quote_identifier, starts_with_row_query};
use crate::value::{duckdb_value_to_json, json_to_duckdb_value, normalized_key_values};

pub struct DuckdbDriver;

impl Driver for DuckdbDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
        let conn = open_duckdb(url)?;
        let trimmed = query.trim().trim_end_matches(';').trim();
        if trimmed.is_empty() {
            bail!("query is empty");
        }

        if starts_with_row_query(trimmed) {
            let mut stmt = conn.prepare(trimmed)?;
            let mut result_rows = stmt.query([])?;
            let statement = result_rows
                .as_ref()
                .context("failed to read duckdb result metadata")?;
            let columns = (0..statement.column_count())
                .map(|index| {
                    Ok(ColumnMeta {
                        name: statement.column_name(index)?.to_string(),
                    })
                })
                .collect::<duckdb::Result<Vec<_>>>()?;
            let mut rows = Vec::new();
            while let Some(row) = result_rows.next()? {
                let mut values = Vec::new();
                for index in 0..columns.len() {
                    values.push(duckdb_value_to_json(row.get_ref(index)?));
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
        let conn = open_duckdb(url)?;
        let mut stmt = conn.prepare(
            "
            select table_schema, table_name, lower(table_type)
            from information_schema.tables
            where table_schema not in ('information_schema', 'pg_catalog')
            order by table_schema, table_name
            ",
        )?;
        let items = stmt
            .query_map([], |row| {
                let materialization: String = row.get(2)?;
                Ok(StructureItem {
                    schema: Some(row.get::<_, String>(0)?),
                    name: row.get::<_, String>(1)?,
                    materialization: match materialization.as_str() {
                        "base table" => "table".to_string(),
                        other => other.to_string(),
                    },
                })
            })?
            .collect::<duckdb::Result<Vec<_>>>()?;
        Ok(items)
    }

    fn columns(
        &self,
        url: &str,
        table: &str,
        schema: Option<String>,
        _materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>> {
        let conn = open_duckdb(url)?;
        let schema = schema.unwrap_or_else(|| "main".to_string());
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
            where table_schema = ? and table_name = ?
            order by ordinal_position
        ";
        let mut stmt = conn.prepare(query)?;
        let columns = stmt
            .query_map([schema, table.to_string()], |row| {
                Ok(ColumnInfo {
                    name: row.get::<_, String>(0)?,
                    data_type: row.get::<_, String>(1)?,
                    nullable: row.get::<_, String>(2)? == "YES",
                    default_value: row.get::<_, Option<String>>(3)?,
                    ordinal_position: row.get::<_, i64>(4)?,
                    primary_key: matches!(row.get_ref(5)?, ValueRef::Boolean(true)),
                })
            })?
            .collect::<duckdb::Result<Vec<_>>>()?;
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
            .unwrap_or_else(|| duckdb_display_name(url));
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
        let conn = open_duckdb(url).context("failed to open duckdb database")?;
        let mut params = vec![json_to_duckdb_value(value)?];
        let mut clauses = Vec::new();

        for (name, _, key_value) in normalized_key_values(keys)? {
            if key_value.is_null() {
                clauses.push(format!(
                    "{} IS NULL",
                    quote_identifier(DriverKind::Duckdb, &name)
                ));
            } else {
                clauses.push(format!(
                    "{} = ?{}",
                    quote_identifier(DriverKind::Duckdb, &name),
                    params.len() + 1
                ));
                params.push(json_to_duckdb_value(&key_value)?);
            }
        }

        let query = format!(
            "UPDATE {} SET {} = ?1 WHERE {}",
            qualify_table_name(DriverKind::Duckdb, schema, table),
            quote_identifier(DriverKind::Duckdb, &column.name),
            clauses.join(" AND ")
        );
        Ok(conn.execute(&query, duckdb::params_from_iter(params))? as u64)
    }
}

fn open_duckdb(url: &str) -> Result<duckdb::Connection> {
    let path = duckdb_path(url);
    if path.is_empty() || path == ":memory:" {
        duckdb::Connection::open_in_memory().context("failed to open duckdb in-memory database")
    } else {
        duckdb::Connection::open(path).context("failed to open duckdb database")
    }
}

fn duckdb_display_name(url: &str) -> String {
    let path = duckdb_path(url);
    if path.is_empty() || path == ":memory:" {
        return "memory".to_string();
    }
    std::path::Path::new(&path)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or(&path)
        .to_string()
}
