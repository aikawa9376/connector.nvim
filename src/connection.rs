use anyhow::{bail, Context, Result};
use regex::Regex;
use url::Url;

use crate::driver::{normalize_kind, DriverKind};
use crate::protocol::ConnectionInput;

pub fn effective_url(connection: &ConnectionInput) -> Result<String> {
    let mut url = expand_template(&connection.url)?;
    if let Some(database) = connection
        .database
        .as_ref()
        .filter(|value| !value.is_empty())
    {
        url = apply_database_override(&url, &connection.kind, database)?;
    }
    Ok(url)
}

fn expand_template(input: &str) -> Result<String> {
    let pattern = Regex::new(r#"\{\{\s*(env|exec)\s+((?:\"[^\"]*\")|(?:`[^`]*`))\s*\}\}"#)?;
    let mut output = String::new();
    let mut last = 0usize;
    for capture in pattern.captures_iter(input) {
        let matched = capture.get(0).unwrap();
        output.push_str(&input[last..matched.start()]);
        let mode = capture.get(1).unwrap().as_str();
        let raw = capture.get(2).unwrap().as_str();
        let arg = raw.trim_matches('"').trim_matches('`');
        let replacement = match mode {
            "env" => std::env::var(arg).unwrap_or_default(),
            "exec" => shell_exec(arg)?,
            _ => String::new(),
        };
        output.push_str(&replacement);
        last = matched.end();
    }
    output.push_str(&input[last..]);
    Ok(output)
}

#[cfg(target_os = "windows")]
fn shell_exec(command: &str) -> Result<String> {
    let output = std::process::Command::new("cmd")
        .args(["/C", command])
        .output()
        .with_context(|| format!("failed to execute command: {command}"))?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(not(target_os = "windows"))]
fn shell_exec(command: &str) -> Result<String> {
    let output = std::process::Command::new("sh")
        .args(["-lc", command])
        .output()
        .with_context(|| format!("failed to execute command: {command}"))?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn apply_database_override(raw_url: &str, kind: &str, database: &str) -> Result<String> {
    let driver = normalize_kind(kind)?;
    if driver == DriverKind::Sqlite {
        return Ok(raw_url.to_string());
    }

    let mut parsed = Url::parse(raw_url)
        .with_context(|| format!("expected URL connection string: {raw_url}"))?;
    parsed.set_path(&format!("/{database}"));
    Ok(parsed.to_string())
}
