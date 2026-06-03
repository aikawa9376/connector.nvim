use anyhow::{bail, Result};
use serde_json::Value;

use crate::protocol::{
    ColumnInfo, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};

pub mod mysql;
pub mod postgres;
pub mod sqlite;

pub trait Driver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse>;
    fn structure(&self, url: &str) -> Result<Vec<StructureItem>>;
    fn columns(
        &self,
        url: &str,
        table: &str,
        schema: Option<String>,
        materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>>;
    fn list_databases(
        &self,
        url: &str,
        connection: &ConnectionInput,
    ) -> Result<ListDatabasesResponse>;
    fn update_row(
        &self,
        url: &str,
        table: &str,
        schema: Option<&str>,
        column: &ColumnUpdateInput,
        keys: &[KeyFieldInput],
        value: &Value,
    ) -> Result<u64>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriverKind {
    Sqlite,
    Postgres,
    Mysql,
}

pub fn normalize_kind(kind: &str) -> Result<DriverKind> {
    match kind.to_ascii_lowercase().as_str() {
        "sqlite" | "sqlite3" => Ok(DriverKind::Sqlite),
        "postgres" | "postgresql" | "pg" => Ok(DriverKind::Postgres),
        "mysql" | "mariadb" => Ok(DriverKind::Mysql),
        other => bail!("unsupported connection type: {other}"),
    }
}

static SQLITE_DRIVER: sqlite::SqliteDriver = sqlite::SqliteDriver;
static POSTGRES_DRIVER: postgres::PostgresDriver = postgres::PostgresDriver;
static MYSQL_DRIVER: mysql::MysqlDriver = mysql::MysqlDriver;

impl DriverKind {
    pub fn driver(&self) -> &'static dyn Driver {
        match self {
            DriverKind::Sqlite => &SQLITE_DRIVER,
            DriverKind::Postgres => &POSTGRES_DRIVER,
            DriverKind::Mysql => &MYSQL_DRIVER,
        }
    }
}
