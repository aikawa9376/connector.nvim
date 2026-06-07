use std::convert::TryInto;

use anyhow::{bail, Context, Result};
use mongodb::bson::{Bson, Document};
use mongodb::sync::{Client, Database};
use serde_json::Value;
use url::Url;

use crate::driver::Driver;
use crate::protocol::{
    ColumnInfo, ColumnMeta, ColumnUpdateInput, ConnectionInput, ExecuteResponse, KeyFieldInput,
    ListDatabasesResponse, StructureItem,
};

pub struct MongoDriver;

impl Driver for MongoDriver {
    fn execute(&self, url: &str, query: &str) -> Result<ExecuteResponse> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            bail!("query is empty");
        }

        let client = mongo_client(url)?;
        let database = current_database(&client, url)?;
        let command = parse_mongo_command(trimmed)?;
        let response = database.run_command(command).run()?;
        let rows = mongo_response_to_rows(response);

        Ok(ExecuteResponse {
            columns: vec![ColumnMeta {
                name: "Reply".to_string(),
            }],
            row_count: rows.len(),
            rows,
            message: None,
        })
    }

    fn structure(&self, url: &str) -> Result<Vec<StructureItem>> {
        let client = mongo_client(url)?;
        let database = current_database(&client, url)?;
        let collections = database.list_collection_names().run()?;
        Ok(collections
            .into_iter()
            .map(|name| StructureItem {
                schema: None,
                name,
                materialization: "table".to_string(),
            })
            .collect())
    }

    fn columns(
        &self,
        _url: &str,
        _table: &str,
        _schema: Option<String>,
        _materialization: Option<String>,
    ) -> Result<Vec<ColumnInfo>> {
        Ok(vec![ColumnInfo {
            name: "Reply".to_string(),
            data_type: "collection".to_string(),
            nullable: true,
            default_value: None,
            ordinal_position: 1,
            primary_key: false,
        }])
    }

    fn list_databases(
        &self,
        url: &str,
        _connection: &ConnectionInput,
    ) -> Result<ListDatabasesResponse> {
        let client = mongo_client(url)?;
        let current = current_database_name(&client, url)?;
        let mut available = client.list_database_names().run()?;
        if !available.iter().any(|name| name == &current) {
            available.insert(0, current.clone());
        }

        Ok(ListDatabasesResponse { current, available })
    }

    fn update_row(
        &self,
        _url: &str,
        _table: &str,
        _schema: Option<&str>,
        _column: &ColumnUpdateInput,
        _keys: &[KeyFieldInput],
        _value: &Value,
    ) -> Result<u64> {
        bail!("row updates are not supported for mongodb")
    }
}

fn mongo_client(url: &str) -> Result<Client> {
    Client::with_uri_str(url).context("failed to create mongodb client")
}

fn current_database(client: &Client, url: &str) -> Result<Database> {
    Ok(client.database(&current_database_name(client, url)?))
}

fn current_database_name(client: &Client, url: &str) -> Result<String> {
    if let Some(name) = mongo_database_from_url(url) {
        return Ok(name);
    }

    if let Some(database) = client.default_database() {
        return Ok(database.name().to_string());
    }

    let databases = client.list_database_names().run()?;
    Ok(databases
        .into_iter()
        .next()
        .unwrap_or_else(|| "admin".to_string()))
}

fn mongo_database_from_url(raw_url: &str) -> Option<String> {
    let parsed = Url::parse(raw_url).ok()?;
    let path = parsed.path().trim_matches('/');
    if path.is_empty() {
        None
    } else {
        Some(path.to_string())
    }
}

fn parse_mongo_command(query: &str) -> Result<Document> {
    let json: Value =
        serde_json::from_str(query).context("failed to decode MongoDB command JSON")?;
    let bson: Bson = json.try_into().context("failed to convert JSON to BSON")?;
    match bson {
        Bson::Document(document) => Ok(document),
        _ => bail!("MongoDB command must be a JSON object"),
    }
}

fn mongo_response_to_rows(mut response: Document) -> Vec<Vec<Value>> {
    if let Some(Bson::Document(mut cursor)) = response.remove("cursor") {
        if let Some(Bson::Array(batch)) = cursor
            .remove("firstBatch")
            .or_else(|| cursor.remove("nextBatch"))
        {
            return batch
                .into_iter()
                .map(|value| vec![bson_to_json(value)])
                .collect();
        }
    }

    vec![vec![bson_to_json(Bson::Document(response))]]
}

fn bson_to_json(value: Bson) -> Value {
    value.into()
}
