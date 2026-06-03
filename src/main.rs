mod app;
mod cli;
mod connection;
mod driver;
mod protocol;
mod sql;
mod value;

use std::io::{self, Read};

use anyhow::{Context, Result};
use clap::Parser;
use serde::{Deserialize, Serialize};
use serde_json::json;

fn main() {
    if let Err(err) = run() {
        let payload = json!({ "error": format!("{err:#}") });
        println!(
            "{}",
            serde_json::to_string(&payload)
                .unwrap_or_else(|_| "{\"error\":\"unknown error\"}".to_string())
        );
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = cli::Cli::parse();
    match cli.command {
        cli::Command::Execute => {
            let request: protocol::ExecuteRequest = read_stdin_json()?;
            print_json(&app::execute(request.connection, request.query)?)?;
        }
        cli::Command::Structure => {
            let request: protocol::ConnectionRequest = read_stdin_json()?;
            print_json(&app::structure(request.connection)?)?;
        }
        cli::Command::Columns => {
            let request: protocol::ColumnsRequest = read_stdin_json()?;
            print_json(&app::columns(
                request.connection,
                request.table,
                request.schema,
                request.materialization,
            )?)?;
        }
        cli::Command::ListDatabases => {
            let request: protocol::ConnectionRequest = read_stdin_json()?;
            print_json(&app::list_databases(request.connection)?)?;
        }
        cli::Command::UpdateRow => {
            let request: protocol::UpdateRowRequest = read_stdin_json()?;
            print_json(&app::update_row(
                request.connection,
                request.table,
                request.schema,
                request.column,
                request.keys,
                request.new_value_text,
            )?)?;
        }
    }

    Ok(())
}

fn read_stdin_json<T: for<'de> Deserialize<'de>>() -> Result<T> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    serde_json::from_str(&input).context("failed to decode request JSON")
}

fn print_json<T: Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string(value)?);
    Ok(())
}
