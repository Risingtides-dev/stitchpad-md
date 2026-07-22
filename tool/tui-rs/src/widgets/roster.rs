use crate::theme;
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Widget},
};
use std::fs;
use std::process::Command;

/// Live status of a roster member
#[derive(Debug, Clone)]
pub enum LiveStatus {
    Online,
    Offline,
    Dnd,
}

impl LiveStatus {
    fn icon(&self) -> &str {
        match self {
            LiveStatus::Online => "●",
            LiveStatus::Offline => "○",
            LiveStatus::Dnd => "◌",
        }
    }

    fn color(&self) -> Color {
        let t = theme::t();
        match self {
            LiveStatus::Online => t.ok,
            LiveStatus::Offline => t.faint,
            LiveStatus::Dnd => t.warn,
        }
    }
}

/// Health status of a roster member
#[derive(Debug, Clone, PartialEq)]
pub enum Health {
    Healthy,
    Untargeted,
    StaleTarget,
    MissingIdentity,
    Unknown,
}

impl Health {
    fn icon(&self) -> &str {
        match self {
            Health::Healthy => "✓",
            Health::Untargeted => "⚠",
            Health::StaleTarget => "✗",
            Health::MissingIdentity => "⚠",
            Health::Unknown => "?",
        }
    }

    fn color(&self) -> Color {
        let t = theme::t();
        match self {
            Health::Healthy => t.ok,
            Health::Untargeted => t.warn,
            Health::StaleTarget => t.err,
            Health::MissingIdentity => t.warn,
            Health::Unknown => t.muted,
        }
    }
}

/// A roster member with health and live status
#[derive(Debug, Clone)]
pub struct RosterMember {
    pub name: String,
    pub adapter: String,
    pub wake: String,
    pub harness: String,
    pub model: String,
    pub health: Health,
    pub live_status: LiveStatus,
    pub issue: Option<String>,
}

/// Roster rail widget
pub struct RosterRail {
    pub members: Vec<RosterMember>,
    pub selected: usize,
}

impl RosterRail {
    /// Create a new roster rail by running `stitchpad doctor` and parsing the output
    pub fn from_doctor() -> Self {
        let members = Self::fetch();
        Self {
            members,
            selected: 0,
        }
    }

    /// Fetch a fresh member list (doctor shell-out + liveness probes), deduped by
    /// name. Static so a background thread can run it without borrowing the widget —
    /// the doctor fork + kill -0 probes are too slow for the draw loop.
    pub fn fetch() -> Vec<RosterMember> {
        let mut members = Self::parse_doctor_output();
        let mut seen = std::collections::HashSet::new();
        members.retain(|m| seen.insert(m.name.clone()));
        members
    }

    /// Replace members from a background fetch, keeping the selection clamped.
    pub fn set_members(&mut self, members: Vec<RosterMember>) {
        self.members = members;
        if self.selected >= self.members.len() {
            self.selected = self.members.len().saturating_sub(1);
        }
    }

    /// Is the pad watcher daemon running? (lock dir + live pid — same check the
    /// CLI uses). Probed in the background refresh thread, shown in the header.
    pub fn watcher_alive() -> bool {
        let pid = match fs::read_to_string(format!("{}/watch.lock.d/pid", crate::pad_state())) {
            Ok(s) => s.trim().to_string(),
            Err(_) => return false,
        };
        if pid.is_empty() {
            return false;
        }
        Command::new("kill")
            .args(["-0", &pid])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    /// Parse the output of `stitchpad doctor`
    fn parse_doctor_output() -> Vec<RosterMember> {
        let output = Command::new("stitchpad")
            .arg("doctor")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .unwrap_or_default();

        let mut members = Vec::new();

        for line in output.lines() {
            // Stop at "Session files:" — that's a separate section, not roster members
            let trimmed = line.trim();
            if trimmed.starts_with("Session files:") {
                break;
            }

            // Parse lines like:
            //   ✓ @dale (herdr/push) — healthy
            //   ⚠ @larry (herdr/push) — target '-' (no wake target, unreachable)
            //   ✗ @old-agent (herdr/push) — unknown adapter
            if !trimmed.starts_with("✓")
                && !trimmed.starts_with("⚠")
                && !trimmed.starts_with("✗")
                && !trimmed.starts_with("?")
            {
                continue;
            }

            // The LEADING GLYPH is the health signal — capture it. Doctor's wording
            // after the glyph keeps changing (healthy → online/offline/operator), so
            // parsing health from words is fragile and broke the roster (everyone read
            // as '?'). The glyph is stable: ✓=healthy ⚠=warn ✗=stale ?=unknown.
            let glyph = trimmed.chars().next().unwrap_or('?');

            // Strip health icon + trailing space by char, not byte.
            // Icons (✓⚠✗?) are 3/3/3/1 UTF-8 bytes; byte-slice panics on 3-byte codepoints.
            let rest = trimmed
                .chars()
                .skip(1) // skip health icon
                .collect::<String>()
                .trim()
                .to_string();

            // Extract @name
            let name = if let Some(at_pos) = rest.find('@') {
                let after_at = &rest[at_pos + 1..];
                after_at
                    .split_whitespace()
                    .next()
                    .and_then(|s| {
                        s.split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
                            .next()
                    })
                    .unwrap_or("")
                    .to_string()
            } else {
                continue;
            };

            // Extract adapter/wake from (adapter/wake)
            let adapter = rest
                .split('(')
                .nth(1)
                .and_then(|s| s.split('/').next())
                .unwrap_or("")
                .to_string();
            let wake = rest
                .split('/')
                .nth(1)
                .and_then(|s| s.split(')').next())
                .unwrap_or("")
                .to_string();

            // Determine health
            let (health, issue) = if glyph == '✓' {
                (Health::Healthy, None)        // doctor already vetted it — trust the glyph
            } else if glyph == '⚠' {
                (Health::Untargeted, Some(rest.clone()))
            } else if glyph == '✗' {
                (Health::StaleTarget, Some(rest.clone()))
            } else if rest.contains("healthy") || rest.contains("operator") {
                (Health::Healthy, None)
            } else if rest.contains("target '-'") || rest.contains("no wake target") {
                (Health::Untargeted, Some("no wake target".to_string()))
            } else if rest.contains("stale target") || rest.contains("gone") {
                (Health::StaleTarget, Some("window gone".to_string()))
            } else if rest.contains("no session identity") {
                (
                    Health::MissingIdentity,
                    Some("no session identity".to_string()),
                )
            } else {
                (Health::Unknown, Some(rest.to_string()))
            };

            // Determine live status: DND flag wins, then real heartbeat liveness
            // (same signal the bridge/PWA use — alive.<name> fresh <90s AND pid alive),
            // NOT doctor health. A crashed agent with a healthy wake target is offline.
            let live_status =
                if std::path::Path::new(&format!("{}/dnd.{}", crate::pad_state(), name)).exists() {
                    LiveStatus::Dnd
                } else if Self::is_online(&name) {
                    LiveStatus::Online
                } else {
                    LiveStatus::Offline
                };

            let (harness, model) = Self::member_metadata(&name, &adapter);

            members.push(RosterMember {
                name,
                adapter,
                wake,
                harness,
                model,
                health,
                live_status,
                issue,
            });
        }

        members
    }

    /// Refresh the roster from the current doctor output
    pub fn refresh(&mut self) {
        let members = Self::fetch();
        self.set_members(members);
    }

    /// Select the next member
    pub fn next(&mut self) {
        if !self.members.is_empty() {
            self.selected = (self.selected + 1) % self.members.len();
        }
    }

    /// Select the previous member
    pub fn previous(&mut self) {
        if !self.members.is_empty() {
            self.selected = (self.selected + self.members.len() - 1) % self.members.len();
        }
    }

    /// Get the currently selected member
    pub fn selected(&self) -> Option<&RosterMember> {
        self.members.get(self.selected)
    }

    fn member_metadata(name: &str, adapter: &str) -> (String, String) {
        let harness = Self::state_value("runtime", name)
            .or_else(|| Self::state_value("harness", name))
            .unwrap_or_else(|| {
                if adapter.trim().is_empty() {
                    "—".to_string()
                } else {
                    adapter.to_string()
                }
            });
        let model = Self::state_value("model", name).unwrap_or_else(|| "—".to_string());
        (harness, model)
    }

    /// Real liveness: heartbeat file fresh (<90s) AND pid still alive.
    /// Mirrors bridge.sh — alive.<name> is `{"pid":N,...}`, mtime is the freshness clock.
    fn is_online(name: &str) -> bool {
        let path = format!("{}/alive.{}", crate::pad_state(), name);
        let meta = match fs::metadata(&path) {
            Ok(m) => m,
            Err(_) => return false,
        };
        let fresh = meta
            .modified()
            .ok()
            .and_then(|t| t.elapsed().ok())
            .map(|age| age.as_secs() < 90)
            .unwrap_or(false);
        if !fresh {
            return false;
        }
        // pid alive? parse "pid":N from the json, kill -0 via libc.
        let pid = fs::read_to_string(&path).ok().and_then(|s| {
            s.split("\"pid\":")
                .nth(1)
                .and_then(|t| t.trim_start().split(|c: char| !c.is_ascii_digit()).next())
                .and_then(|d| d.parse::<i32>().ok())
        });
        match pid {
            // ponytail: kill(pid,0) is the same liveness probe bash uses; no libc crate needed
            Some(p) => Command::new("kill")
                .args(["-0", &p.to_string()])
                .status()
                .map(|s| s.success())
                .unwrap_or(false),
            None => false,
        }
    }

    fn state_value(prefix: &str, name: &str) -> Option<String> {
        let path = format!("{}/{}.{}", crate::pad_state(), prefix, name);
        fs::read_to_string(path)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
}

impl Widget for &RosterRail {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let t = theme::t();
        let block = Block::default()
            .title(Line::from(Span::styled(
                " flock ",
                Style::default().fg(t.muted),
            )))
            .borders(Borders::ALL)
            .border_style(Style::default().fg(t.faint));

        let inner = block.inner(area);
        block.render(area, buf);

        if self.members.is_empty() {
            let empty = Line::from(Span::styled(
                "  the flock is out",
                Style::default().fg(t.muted),
            ));
            buf.set_line(inner.x, inner.y, &empty, inner.width);
            return;
        }

        let compact = inner.height < (self.members.len() as u16).saturating_mul(2);

        for (i, member) in self.members.iter().enumerate() {
            let y = inner.y + if compact { i as u16 } else { (i as u16) * 2 };
            if y >= inner.y + inner.height {
                break;
            }

            // Name uses the shared author color (matches the pad + terminal surface).
            // CLUTTER RULE: the health glyph appears ONLY when something is wrong —
            // a ✓/⚠ on every row marks nothing. Healthy = just the live dot + name.
            let name_color = crate::color::color_for(&member.name);
            let name_style = Style::default().fg(name_color).add_modifier(Modifier::BOLD);
            let live_style = Style::default().fg(member.live_status.color());

            let mut row = vec![
                Span::styled(format!(" {} ", member.live_status.icon()), live_style),
                Span::styled(format!("@{}", member.name), name_style),
            ];
            if member.health != Health::Healthy {
                row.push(Span::styled(
                    format!("  {}", member.health.icon()),
                    Style::default().fg(member.health.color()),
                ));
            }
            buf.set_line(inner.x, y, &Line::from(row), inner.width);

            if !compact && y + 1 < inner.y + inner.height {
                let value = Style::default().fg(t.faint);
                let mut meta = format!("   {}", member.harness);
                if member.model != "—" && !member.model.is_empty() {
                    meta.push_str(&format!(" · {}", member.model));
                }
                if !member.wake.is_empty() {
                    meta.push_str(&format!(" · {}", member.wake));
                }
                let meta_line = Line::from(Span::styled(meta, value));
                buf.set_line(inner.x, y + 1, &meta_line, inner.width);
            }
        }

        // A little grazing scene at the rail's foot — only when there's spare
        // room (never crowds a full flock; pure lore, zero information cost).
        let used = (self.members.len() as u16).saturating_mul(if compact { 1 } else { 2 });
        let sheep_h = 10u16; // sheep + grass + a breath
        if inner.height > used + sheep_h {
            let pad = (inner.width.saturating_sub(22) / 2) as usize;
            let art = crate::logo::sheep(pad);
            let mut y = inner.y + inner.height - art.len() as u16;
            for line in &art {
                buf.set_line(inner.x, y, line, inner.width);
                y += 1;
            }
        }
    }
}
