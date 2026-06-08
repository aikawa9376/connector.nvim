use anyhow::{bail, Result};
use serde_json::Value;

use crate::protocol::{
    ColumnInfo, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};

#[cfg(feature = "clickhouse")]
pub mod clickhouse;
#[cfg(feature = "duckdb")]
pub mod duckdb;
#[cfg(feature = "mongo")]
pub mod mongo;
#[cfg(feature = "mysql")]
pub mod mysql;
#[cfg(feature = "oracle")]
pub mod oracle;
#[cfg(feature = "postgres")]
pub mod postgres;
#[cfg(feature = "redis")]
pub mod redis;
#[cfg(feature = "sqlite")]
pub mod sqlite;
#[cfg(feature = "sqlserver")]
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

#[cfg(feature = "sqlite")]
static SQLITE_DRIVER: sqlite::SqliteDriver = sqlite::SqliteDriver;
#[cfg(feature = "postgres")]
static POSTGRES_DRIVER: postgres::PostgresDriver = postgres::PostgresDriver;
#[cfg(feature = "mysql")]
static MYSQL_DRIVER: mysql::MysqlDriver = mysql::MysqlDriver;
#[cfg(feature = "duckdb")]
static DUCKDB_DRIVER: duckdb::DuckdbDriver = duckdb::DuckdbDriver;
#[cfg(feature = "clickhouse")]
static CLICKHOUSE_DRIVER: clickhouse::ClickhouseDriver = clickhouse::ClickhouseDriver;
#[cfg(feature = "sqlserver")]
static SQLSERVER_DRIVER: sqlserver::SqlServerDriver = sqlserver::SqlServerDriver;
#[cfg(feature = "redis")]
static REDIS_DRIVER: redis::RedisDriver = redis::RedisDriver;
#[cfg(feature = "mongo")]
static MONGO_DRIVER: mongo::MongoDriver = mongo::MongoDriver;
#[cfg(feature = "oracle")]
static ORACLE_DRIVER: oracle::OracleDriver = oracle::OracleDriver;

macro_rules! configured_driver {
    ($feature:literal, $driver:expr, $name:literal) => {{
        #[cfg(feature = $feature)]
        {
            Ok($driver)
        }
        #[cfg(not(feature = $feature))]
        {
            bail!(
                "driver `{}` is not enabled in this connector-backend build. Rebuild with `--features {}`",
                $name,
                $feature
            )
        }
    }};
}

impl DriverKind {
    pub fn driver(&self) -> Result<&'static dyn Driver> {
        match self {
            DriverKind::Sqlite => configured_driver!("sqlite", &SQLITE_DRIVER, "sqlite"),
            DriverKind::Postgres => configured_driver!("postgres", &POSTGRES_DRIVER, "postgres"),
            DriverKind::Mysql => configured_driver!("mysql", &MYSQL_DRIVER, "mysql"),
            DriverKind::Duckdb => configured_driver!("duckdb", &DUCKDB_DRIVER, "duckdb"),
            DriverKind::Clickhouse => {
                configured_driver!("clickhouse", &CLICKHOUSE_DRIVER, "clickhouse")
            }
            DriverKind::SqlServer => {
                configured_driver!("sqlserver", &SQLSERVER_DRIVER, "sqlserver")
            }
            DriverKind::Redis => configured_driver!("redis", &REDIS_DRIVER, "redis"),
            DriverKind::Mongo => configured_driver!("mongo", &MONGO_DRIVER, "mongo"),
            DriverKind::Oracle => configured_driver!("oracle", &ORACLE_DRIVER, "oracle"),
        }
    }
}
