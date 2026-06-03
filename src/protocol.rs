use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
pub struct ConnectionInput {
    pub name: Option<String>,
    #[serde(rename = "type")]
    pub kind: String,
    pub url: String,
    pub database: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ExecuteRequest {
    pub connection: ConnectionInput,
    pub query: String,
}

#[derive(Debug, Deserialize)]
pub struct ColumnsRequest {
    pub connection: ConnectionInput,
    pub table: String,
    pub schema: Option<String>,
    pub materialization: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ConnectionRequest {
    pub connection: ConnectionInput,
}

#[derive(Debug, Deserialize)]
pub struct ColumnUpdateInput {
    pub name: String,
    pub data_type: String,
    pub nullable: bool,
}

#[derive(Debug, Deserialize)]
pub struct KeyFieldInput {
    pub name: String,
    pub data_type: String,
    pub nullable: bool,
    pub value: Value,
}

#[derive(Debug, Deserialize)]
pub struct UpdateRowRequest {
    pub connection: ConnectionInput,
    pub table: String,
    pub schema: Option<String>,
    pub column: ColumnUpdateInput,
    pub keys: Vec<KeyFieldInput>,
    pub new_value_text: String,
}

#[derive(Debug, Serialize)]
pub struct ColumnMeta {
    pub name: String,
}

#[derive(Debug, Serialize)]
pub struct ExecuteResponse {
    pub columns: Vec<ColumnMeta>,
    pub rows: Vec<Vec<Value>>,
    pub row_count: usize,
    pub message: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct StructureItem {
    pub schema: Option<String>,
    pub name: String,
    pub materialization: String,
}

#[derive(Debug, Serialize)]
pub struct ColumnInfo {
    pub name: String,
    pub data_type: String,
    pub nullable: bool,
    pub default_value: Option<String>,
    pub ordinal_position: i64,
    pub primary_key: bool,
}

#[derive(Debug, Serialize)]
pub struct ListDatabasesResponse {
    pub current: String,
    pub available: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct UpdateRowResponse {
    pub affected_rows: u64,
    pub value: Value,
}
