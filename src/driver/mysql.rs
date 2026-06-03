use anyhow::{anyhow, Context, Result};
use mysql::prelude::Queryable;
use serde_json::{json, Value};

use crate::driver::{Driver, DriverKind};
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};
use crate::sql::{qualify_table_name, quote_identifier};
use crate::value::{json_to_mysql_value, mysql_value_to_json, normalized_key_values};

pub struct MysqlDriver;

impl Driver for MysqlDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
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

    fn structure(&self, url: &str) -> Result<Vec<StructureItem>> {
        let opts = mysql::Opts::from_url(url)?;
        let pool = mysql::Pool::new(opts)?;
        let mut conn = pool.get_conn()?;
        let query_all = "
            select table_schema, table_name,
              case
                when table_type = 'VIEW' then 'view'
                else 'table'
              end as materialization
            from information_schema.tables
            order by table_schema, table_name
        ";
        let query_for_database = "
            select table_schema, table_name,
              case
                when table_type = 'VIEW' then 'view'
                else 'table'
              end as materialization
            from information_schema.tables
            where table_schema = ?
            order by table_schema, table_name
        ";
        let rows: Vec<(String, String, String)> = match mysql_database_from_url(url) {
            Some(database) => conn.exec(query_for_database, (database,))?,
            None => conn.query(query_all)?,
        };
        Ok(rows
            .into_iter()
            .map(|(schema, name, materialization)| StructureItem {
                schema: Some(schema),
                name,
                materialization,
            })
            .collect())
    }

    fn columns(
        &self,
        url: &str,
        table: &str,
        schema: Option<String>,
        _materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>> {
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
        let rows: Vec<(String, String, String, Option<String>, i64, String)> =
            conn.exec(query, (schema, table))?;
        Ok(rows
            .into_iter()
            .map(
                |(name, data_type, is_nullable, default_value, ordinal_position, column_key)| {
                    ColumnInfo {
                        name,
                        data_type,
                        nullable: is_nullable == "YES",
                        default_value,
                        ordinal_position,
                        primary_key: column_key == "PRI",
                    }
                },
            )
            .collect())
    }

    fn list_databases(
        &self,
        url: &str,
        _connection: &ConnectionInput,
    ) -> Result<ListDatabasesResponse> {
        let opts = mysql::Opts::from_url(url)?;
        let pool = mysql::Pool::new(opts)?;
        let mut conn = pool.get_conn()?;
        let current = conn
            .query_first::<String, _>("select database()")?
            .unwrap_or_default();
        let available: Vec<String> = conn.query("show databases")?;
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
        let opts = mysql::Opts::from_url(url).context("failed to parse mysql connection URL")?;
        let pool = mysql::Pool::new(opts)?;
        let mut conn = pool.get_conn()?;
        let mut params = vec![json_to_mysql_value(value)?];
        let mut clauses = Vec::new();

        for (name, _, key_value) in normalized_key_values(keys)? {
            if key_value.is_null() {
                clauses.push(format!(
                    "{} IS NULL",
                    quote_identifier(DriverKind::Mysql, &name)
                ));
            } else {
                clauses.push(format!(
                    "{} = ?",
                    quote_identifier(DriverKind::Mysql, &name)
                ));
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
}

fn mysql_database_from_url(url: &str) -> Option<String> {
    url::Url::parse(url).ok().and_then(|parsed| {
        let database = parsed.path().trim_start_matches('/');
        if database.is_empty() {
            None
        } else {
            Some(database.to_string())
        }
    })
}
