use crate::driver::DriverKind;

pub fn sqlite_path(url: &str) -> String {
    let trimmed = url.trim();
    if let Some(stripped) = trimmed.strip_prefix("sqlite://") {
        stripped.to_string()
    } else if let Some(stripped) = trimmed.strip_prefix("file:") {
        stripped.to_string()
    } else {
        trimmed.to_string()
    }
}

pub fn duckdb_path(url: &str) -> String {
    let trimmed = url.trim();
    if let Some(stripped) = trimmed.strip_prefix("duckdb://") {
        stripped.to_string()
    } else if let Some(stripped) = trimmed.strip_prefix("duck://") {
        stripped.to_string()
    } else if let Some(stripped) = trimmed.strip_prefix("file:") {
        stripped.to_string()
    } else {
        trimmed.to_string()
    }
}

pub fn quote_sqlite_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

pub fn quote_identifier(kind: DriverKind, value: &str) -> String {
    match kind {
        DriverKind::Mysql | DriverKind::Clickhouse => {
            format!("`{}`", value.replace('`', "``"))
        }
        DriverKind::SqlServer => format!("[{}]", value.replace(']', "]]")),
        DriverKind::Sqlite
        | DriverKind::Postgres
        | DriverKind::Duckdb
        | DriverKind::Redis
        | DriverKind::Mongo
        | DriverKind::Oracle => {
            format!("\"{}\"", value.replace('"', "\"\""))
        }
    }
}

pub fn qualify_table_name(kind: DriverKind, schema: Option<&str>, table: &str) -> String {
    match schema.filter(|value| !value.is_empty()) {
        Some(schema_name) => format!(
            "{}.{}",
            quote_identifier(kind, schema_name),
            quote_identifier(kind, table)
        ),
        None => quote_identifier(kind, table),
    }
}

pub fn starts_with_row_query(query: &str) -> bool {
    let first = query
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        first.as_str(),
        "select" | "with" | "pragma" | "show" | "describe" | "desc" | "explain"
    )
}
