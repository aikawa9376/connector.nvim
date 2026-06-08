use anyhow::{bail, Result};

use crate::connection::effective_url;
use crate::driver::normalize_kind;
use crate::protocol::{
    ColumnInfo, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem, UpdateRowResponse,
};
use crate::value::parse_text_value;

pub fn execute(connection: ConnectionInput, query: String) -> Result<ExecuteResponse> {
    let url = effective_url(&connection)?;
    let kind = normalize_kind(&connection.kind)?;
    kind.driver()?.execute(&url, &query)
}

pub fn structure(connection: ConnectionInput) -> Result<Vec<StructureItem>> {
    let url = effective_url(&connection)?;
    let kind = normalize_kind(&connection.kind)?;
    kind.driver()?.structure(&url)
}

pub fn columns(
    connection: ConnectionInput,
    table: String,
    schema: Option<String>,
    materialization: Option<String>,
) -> Result<Vec<ColumnInfo>> {
    let url = effective_url(&connection)?;
    let kind = normalize_kind(&connection.kind)?;
    kind.driver()?
        .columns(&url, &table, schema, materialization)
}

pub fn list_databases(connection: ConnectionInput) -> Result<ListDatabasesResponse> {
    let url = effective_url(&connection)?;
    let kind = normalize_kind(&connection.kind)?;
    kind.driver()?.list_databases(&url, &connection)
}

pub fn update_row(
    connection: ConnectionInput,
    table: String,
    schema: Option<String>,
    column: ColumnUpdateInput,
    keys: Vec<KeyFieldInput>,
    new_value_text: String,
) -> Result<UpdateRowResponse> {
    if keys.is_empty() {
        bail!("update keys are required");
    }

    let url = effective_url(&connection)?;
    let kind = normalize_kind(&connection.kind)?;
    let value = parse_text_value(&new_value_text, &column.data_type, column.nullable)?;
    let affected_rows =
        kind.driver()?
            .update_row(&url, &table, schema.as_deref(), &column, &keys, &value)?;

    Ok(UpdateRowResponse {
        affected_rows,
        value,
    })
}
