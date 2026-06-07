use anyhow::{bail, Result};
use serde_json::Value;

use crate::protocol::{
    ColumnInfo, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};

pub mod clickhouse;
pub mod duckdb;
pub mod mongo;
pub mod mysql;
pub mod oracle;
pub mod postgres;
pub mod redis;
pub mod sqlite;
pub mod sqlserver;

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
    Duckdb,
    Clickhouse,
    SqlServer,
    Redis,
    Mongo,
    Oracle,
}

pub fn normalize_kind(kind: &str) -> Result<DriverKind> {
    match kind.to_ascii_lowercase().as_str() {
        "sqlite" | "sqlite3" => Ok(DriverKind::Sqlite),
        "postgres" | "postgresql" | "pg" | "redshift" => Ok(DriverKind::Postgres),
        "mysql" | "mariadb" => Ok(DriverKind::Mysql),
        "duck" | "duckdb" => Ok(DriverKind::Duckdb),
        "clickhouse" => Ok(DriverKind::Clickhouse),
        "sqlserver" | "mssql" => Ok(DriverKind::SqlServer),
        "redis" => Ok(DriverKind::Redis),
        "mongo" | "mongodb" => Ok(DriverKind::Mongo),
        "oracle" => Ok(DriverKind::Oracle),
        other => bail!("unsupported connection type: {other}"),
    }
}

static SQLITE_DRIVER: sqlite::SqliteDriver = sqlite::SqliteDriver;
static POSTGRES_DRIVER: postgres::PostgresDriver = postgres::PostgresDriver;
static MYSQL_DRIVER: mysql::MysqlDriver = mysql::MysqlDriver;
static DUCKDB_DRIVER: duckdb::DuckdbDriver = duckdb::DuckdbDriver;
static CLICKHOUSE_DRIVER: clickhouse::ClickhouseDriver = clickhouse::ClickhouseDriver;
static SQLSERVER_DRIVER: sqlserver::SqlServerDriver = sqlserver::SqlServerDriver;
static REDIS_DRIVER: redis::RedisDriver = redis::RedisDriver;
static MONGO_DRIVER: mongo::MongoDriver = mongo::MongoDriver;
static ORACLE_DRIVER: oracle::OracleDriver = oracle::OracleDriver;

impl DriverKind {
    pub fn driver(&self) -> &'static dyn Driver {
        match self {
            DriverKind::Sqlite => &SQLITE_DRIVER,
            DriverKind::Postgres => &POSTGRES_DRIVER,
            DriverKind::Mysql => &MYSQL_DRIVER,
            DriverKind::Duckdb => &DUCKDB_DRIVER,
            DriverKind::Clickhouse => &CLICKHOUSE_DRIVER,
            DriverKind::SqlServer => &SQLSERVER_DRIVER,
            DriverKind::Redis => &REDIS_DRIVER,
            DriverKind::Mongo => &MONGO_DRIVER,
            DriverKind::Oracle => &ORACLE_DRIVER,
        }
    }
}
