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
        match self {
            LiveStatus::Online => Color::Green,
            LiveStatus::Offline => Color::DarkGray,
            LiveStatus::Dnd => Color::Yellow,
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
        match self {
            Health::Healthy => Color::Green,
            Health::Untargeted => Color::Yellow,
            Health::StaleTarget => Color::Red,
            Health::MissingIdentity => Color::Yellow,
            Health::Unknown => Color::Gray,
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
        let members = Self::parse_doctor_output();
        Self {
            members,
            selected: 0,
        }
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
            //   ✓ @dale (kitty/push) — healthy
            //   ⚠ @larry (kitty/push) — target '-' (no wake target, unreachable)
            //   ✗ @old-agent (kitty/push) — stale target — kitty window gone
            if !trimmed.starts_with("✓")
                && !trimmed.starts_with("⚠")
                && !trimmed.starts_with("✗")
                && !trimmed.starts_with("?")
            {
                continue;
            }

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
            let (health, issue) = if rest.contains("healthy") {
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

            // Determine live status (DND flag, then kitty window liveness)
            let live_status =
                if std::path::Path::new(&format!(".stitchpad/.state/dnd.{}", name)).exists() {
                    LiveStatus::Dnd
                } else if health == Health::Healthy {
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
        self.members = Self::parse_doctor_output();
        if self.selected >= self.members.len() {
            self.selected = self.members.len().saturating_sub(1);
        }
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

    fn state_value(prefix: &str, name: &str) -> Option<String> {
        let path = format!(".stitchpad/.state/{}.{}", prefix, name);
        fs::read_to_string(path)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
}

impl Widget for &RosterRail {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let block = Block::default().title(" Roster ").borders(Borders::ALL);

        let inner = block.inner(area);
        block.render(area, buf);

        if self.members.is_empty() {
            let empty = Line::from(Span::styled(
                "  No members",
                Style::default().fg(Color::Gray),
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

            // Name uses the shared author color (matches the pad + the kitty window);
            // status/health dots keep their status colors. Selected row = bold name.
            let name_color = crate::color::color_for(&member.name);
            let name_style = if i == self.selected {
                Style::default().fg(name_color).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(name_color)
            };

            let icon_style = Style::default().fg(member.health.color());
            let live_style = Style::default().fg(member.live_status.color());

            let line = Line::from(vec![
                Span::styled(format!(" {} ", member.live_status.icon()), live_style),
                Span::styled(format!("{} ", member.health.icon()), icon_style),
                Span::styled(format!("@{}", member.name), name_style),
            ]);

            buf.set_line(inner.x, y, &line, inner.width);

            if !compact && y + 1 < inner.y + inner.height {
                let meta = Line::from(vec![
                    Span::raw("    "),
                    Span::styled("harness ", Style::default().fg(Color::DarkGray)),
                    Span::styled(
                        format!("{} ", member.harness),
                        Style::default().fg(Color::Gray),
                    ),
                    Span::styled("· ", Style::default().fg(Color::DarkGray)),
                    Span::styled("model ", Style::default().fg(Color::DarkGray)),
                    Span::styled(&member.model, Style::default().fg(Color::Gray)),
                ]);
                buf.set_line(inner.x, y + 1, &meta, inner.width);
            }
        }
    }
}
