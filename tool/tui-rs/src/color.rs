//! Single source of truth for author colors: the bash CLI `stitchpad color <name>`.
//!
//! The CLI emits the final RGB hex (`#rrggbb`) with the override map applied
//! (e.g. Jill=#ff1493, ernie=#5f2f8f) and the same collision-aware assignment the
//! kitty window backgrounds use. The TUI does NOT reimplement any palette — it
//! shells out and parses the hex, so the board and the terminals can never drift.
//!
//! Resolved colors are cached (one subprocess per author, not per frame). Unknown
//! or unreachable → neutral grey, so rendering never panics.

use std::collections::HashMap;
use std::process::Command;
use std::sync::Mutex;
use ratatui::style::Color;

static CACHE: Mutex<Option<HashMap<String, Color>>> = Mutex::new(None);

/// Author color as `Color::Rgb`, matching that name's terminal/window exactly.
/// Shells `stitchpad color <name>`, parses the `#rrggbb`, caches it.
pub fn color_for(name: &str) -> Color {
    if let Ok(mut guard) = CACHE.lock() {
        let map = guard.get_or_insert_with(HashMap::new);
        if let Some(c) = map.get(name) {
            return *c;
        }
        let c = resolve(name).unwrap_or(Color::Gray);
        map.insert(name.to_string(), c);
        return c;
    }
    resolve(name).unwrap_or(Color::Gray)
}

/// Drop the cache so the next `color_for` re-reads the CLI. Call on roster change /
/// manual refresh so override edits or new members pick up immediately.
pub fn invalidate() {
    if let Ok(mut guard) = CACHE.lock() {
        *guard = None;
    }
}

fn resolve(name: &str) -> Option<Color> {
    let out = Command::new("stitchpad").args(["color", name]).output().ok()?;
    let text = String::from_utf8(out.stdout).ok()?;
    // CLI prints "#rrggbb" (optionally a fg token too); take the first hex color.
    text.split_whitespace().find_map(parse_hex)
}

/// Parse a `#rrggbb` (or bare `rrggbb`) token into `Color::Rgb`. None if not 6 hex.
fn parse_hex(tok: &str) -> Option<Color> {
    let h = tok.trim().trim_start_matches('#');
    if h.len() != 6 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let r = u8::from_str_radix(&h[0..2], 16).ok()?;
    let g = u8::from_str_radix(&h[2..4], 16).ok()?;
    let b = u8::from_str_radix(&h[4..6], 16).ok()?;
    Some(Color::Rgb(r, g, b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hex_forms() {
        assert_eq!(parse_hex("#ff1493"), Some(Color::Rgb(255, 20, 147))); // Jill override
        assert_eq!(parse_hex("5f2f8f"), Some(Color::Rgb(95, 47, 143)));   // ernie, no '#'
        assert_eq!(parse_hex("#ABCDEF"), Some(Color::Rgb(171, 205, 239))); // case-insensitive
        assert_eq!(parse_hex("#fff"), None);   // too short
        assert_eq!(parse_hex("nothex"), None); // non-hex
    }

    #[test]
    fn live_cli_matches_terminal() {
        // integration: when run inside a real pad, the TUI color for a known override
        // must equal the terminal hex. Outside a pad the CLI returns its grey fallback
        // (#808080) — skip the assertion then, so this never fails in CI/crate-dir.
        match resolve("Jill") {
            Some(Color::Rgb(0x80, 0x80, 0x80)) | None => { /* no pad context — skip */ }
            Some(c) => assert_eq!(
                c,
                Color::Rgb(0xff, 0x14, 0x93),
                "Jill must match her window override (#ff1493)"
            ),
        }
    }
}
