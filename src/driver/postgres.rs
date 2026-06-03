use anyhow::{Context, Result};
use postgres::{Client, NoTls, SimpleQueryMessage};
use serde_json::{json, Value};

use crate::driver::{Driver, DriverKind};
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};
use crate::sql::{qualify_table_name, quote_identifier};
use crate::value::{json_to_postgres_param, normalized_key_values};

pub struct PostgresDriver;

impl Driver for PostgresDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
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

    fn structure(&self, url: &str) -> Result<Vec<StructureItem>> {
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

    fn columns(
        &self,
        url: &str,
        table: &str,
        schema: Option<String>,
        _materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>> {
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

    fn list_databases(
        &self,
        url: &str,
        _connection: &ConnectionInput,
    ) -> Result<ListDatabasesResponse> {
        let mut client = Client::connect(url, NoTls)?;
        let current = client
            .query_one("select current_database()", &[])?
            .get::<_, String>(0);
        let available = client
            .query(
                "select datname from pg_database where datistemplate = false order by datname",
                &[],
            )?
            .into_iter()
            .map(|row| row.get::<_, String>(0))
            .collect();
        Ok(ListDatabasesResponse { current, available })
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
        let mut client = Client::connect(url, NoTls).context("failed to connect to postgres")?;
        let mut params = vec![json_to_postgres_param(value)?];
        let mut clauses = Vec::new();

        for (name, _, key_value) in normalized_key_values(keys)? {
            if key_value.is_null() {
                clauses.push(format!(
                    "{} IS NULL",
                    quote_identifier(DriverKind::Postgres, &name)
                ));
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
        let param_refs = params
            .iter()
            .map(|value| value.as_ref())
            .collect::<Vec<_>>();
        Ok(client.execute(&query, &param_refs)?)
    }
}
