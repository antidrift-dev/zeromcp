use crate::types::Permissions;

/// Log elevated permissions at startup (mirrors the Node.js `validatePermissions`).
pub fn validate_permissions(name: &str, permissions: &Permissions) {
    let mut elevated = Vec::new();
    if let Some(ref fs) = permissions.fs {
        elevated.push(format!("fs: {fs}"));
    }
    if permissions.exec {
        elevated.push("exec".to_string());
    }
    if !elevated.is_empty() {
        eprintln!(
            "[zeromcp] {name} requests elevated permissions: {}",
            elevated.join(" | ")
        );
    }
}

/// Check whether a hostname is allowed by the network allowlist.
pub fn is_network_allowed(hostname: &str, allowlist: &[String]) -> bool {
    allowlist.iter().any(|pattern| {
        if let Some(suffix) = pattern.strip_prefix("*.") {
            hostname.ends_with(&format!(".{suffix}")) || hostname == suffix
        } else {
            hostname == pattern
        }
    })
}

/// Check whether a network request to `url` is permitted given the tool's
/// permissions. Returns `Ok(())` if allowed, `Err(message)` if denied.
pub fn check_network(
    name: &str,
    url: &str,
    permissions: &Permissions,
    bypass: bool,
    logging: bool,
) -> Result<(), String> {
    let hostname = extract_hostname(url);

    match &permissions.network {
        // No restriction / full access
        None => {
            if logging {
                eprintln!("[zeromcp] {name} -> {hostname}");
            }
            Ok(())
        }
        // Allowlist
        Some(allowlist) if !allowlist.is_empty() => {
            if is_network_allowed(&hostname, allowlist) {
                if logging {
                    eprintln!("[zeromcp] {name} -> {hostname}");
                }
                Ok(())
            } else if bypass {
                if logging {
                    eprintln!(
                        "[zeromcp] ! {name} -> {hostname} (not in allowlist -- bypassed)"
                    );
                }
                Ok(())
            } else {
                if logging {
                    eprintln!(
                        "[zeromcp] {name} x {hostname} (not in allowlist)"
                    );
                }
                Err(format!(
                    "[zeromcp] {name}: network access denied for {hostname} (allowed: {})",
                    allowlist.join(", ")
                ))
            }
        }
        // Empty list = network disabled
        Some(_) => {
            if bypass {
                if logging {
                    eprintln!(
                        "[zeromcp] ! {name} -> {hostname} (network disabled -- bypassed)"
                    );
                }
                Ok(())
            } else {
                if logging {
                    eprintln!("[zeromcp] {name} x {hostname} (network disabled)");
                }
                Err(format!("[zeromcp] {name}: network access denied"))
            }
        }
    }
}

fn extract_hostname(url: &str) -> String {
    // Minimal hostname extraction without pulling in the `url` crate.
    let after_scheme = url
        .find("://")
        .map(|i| &url[i + 3..])
        .unwrap_or(url);
    let host_port = after_scheme.split('/').next().unwrap_or(after_scheme);
    host_port.split(':').next().unwrap_or(host_port).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wildcard_matching() {
        let list = vec!["*.example.com".to_string()];
        assert!(is_network_allowed("api.example.com", &list));
        assert!(is_network_allowed("example.com", &list));
        assert!(!is_network_allowed("evil.com", &list));
    }

    #[test]
    fn exact_matching() {
        let list = vec!["api.example.com".to_string()];
        assert!(is_network_allowed("api.example.com", &list));
        assert!(!is_network_allowed("other.example.com", &list));
    }

    #[test]
    fn extract_hostname_works() {
        assert_eq!(extract_hostname("https://api.example.com/v1"), "api.example.com");
        assert_eq!(extract_hostname("http://localhost:8080/path"), "localhost");
    }

    #[test]
    fn no_permissions_allows_all() {
        let perms = Permissions::default();
        assert!(check_network("test", "https://anywhere.com", &perms, false, false).is_ok());
    }

    #[test]
    fn empty_allowlist_denies() {
        let perms = Permissions {
            network: Some(vec![]),
            ..Default::default()
        };
        assert!(check_network("test", "https://evil.com", &perms, false, false).is_err());
    }

    #[test]
    fn empty_allowlist_bypass() {
        let perms = Permissions {
            network: Some(vec![]),
            ..Default::default()
        };
        assert!(check_network("test", "https://evil.com", &perms, true, false).is_ok());
    }

    #[test]
    fn allowlist_permits_listed_host() {
        let perms = Permissions {
            network: Some(vec!["api.example.com".to_string()]),
            ..Default::default()
        };
        assert!(check_network("test", "https://api.example.com/v1", &perms, false, false).is_ok());
    }

    #[test]
    fn allowlist_denies_unlisted_host() {
        let perms = Permissions {
            network: Some(vec!["api.example.com".to_string()]),
            ..Default::default()
        };
        assert!(check_network("test", "https://evil.com", &perms, false, false).is_err());
    }
}
