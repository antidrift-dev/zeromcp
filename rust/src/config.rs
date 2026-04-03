use serde::{Deserialize, Serialize};
use std::path::Path;

/// Configuration loaded from `zeromcp.config.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Whether to log sandbox decisions to stderr.
    #[serde(default)]
    pub logging: bool,

    /// Bypass permission checks (allow everything with a warning).
    #[serde(default)]
    pub bypass_permissions: bool,

    /// Tool-name separator (default `_`).
    #[serde(default = "default_separator")]
    pub separator: String,
}

fn default_separator() -> String {
    "_".to_string()
}

impl Default for Config {
    fn default() -> Self {
        Self {
            logging: false,
            bypass_permissions: false,
            separator: "_".to_string(),
        }
    }
}

/// Attempt to load a `Config` from a JSON file. Returns `Config::default()`
/// if the file does not exist.
pub fn load_config(path: &str) -> Config {
    let p = Path::new(path);
    if !p.exists() {
        return Config::default();
    }
    match std::fs::read_to_string(p) {
        Ok(raw) => serde_json::from_str(&raw).unwrap_or_else(|e| {
            eprintln!("[zeromcp] Warning: failed to parse config: {e}");
            Config::default()
        }),
        Err(e) => {
            eprintln!("[zeromcp] Warning: failed to read config: {e}");
            Config::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_returns_default() {
        let cfg = load_config("/tmp/nonexistent_zeromcp_config_12345.json");
        assert!(!cfg.logging);
        assert!(!cfg.bypass_permissions);
        assert_eq!(cfg.separator, "_");
    }

    #[test]
    fn deserialize_config() {
        let json = r#"{"logging": true, "bypass_permissions": true, "separator": "."}"#;
        let cfg: Config = serde_json::from_str(json).unwrap();
        assert!(cfg.logging);
        assert!(cfg.bypass_permissions);
        assert_eq!(cfg.separator, ".");
    }
}
