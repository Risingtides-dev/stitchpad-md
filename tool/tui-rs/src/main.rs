mod color;
mod widgets;

use std::io;
use std::sync::mpsc;
use std::path::Path;
use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind},
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    execute,
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    Terminal,
};
use notify::{RecursiveMode, Watcher};

fn main() -> io::Result<()> {
    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Create roster rail + message list
    let mut roster = widgets::roster::RosterRail::from_doctor();
    let mut messages = widgets::messages::MessageList::from_pad();

    // Compose mode state (wires 'a' compose key; @mark builds the compose widget)
    let mut composing = false;
    let mut compose_buf = String::new();
    let mut focus: u8 = 0; // 0=roster, 1=messages, 2=compose
    let focus_labels = ["roster", "messages", "compose"];

    // Live-tail: watch .stitchpad/stitchpad.md and signal the loop to re-read on change.
    // notify runs its own thread; we only poll the channel non-blockingly below.
    let (watch_tx, watch_rx) = mpsc::channel::<()>();
    let _watcher = {
        let pad = Path::new(".stitchpad/stitchpad.md").to_path_buf();
        let tx = watch_tx.clone();
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if res.is_ok() {
                let _ = tx.send(());
            }
        })
        .and_then(|mut w| {
            // watch the dir (editors/append may replace the inode); filter is cheap.
            w.watch(Path::new(".stitchpad"), RecursiveMode::NonRecursive)?;
            Ok(w)
        })
        .ok()
        .map(|w| { let _ = &pad; w }) // keep watcher alive for the program's lifetime
    };

    loop {
        // Live-tail: if the pad changed since last frame, re-read it. Drain all
        // pending events so a burst of writes collapses into one refresh.
        let mut changed = false;
        while watch_rx.try_recv().is_ok() {
            changed = true;
        }
        if changed {
            messages.refresh();
        }

        // Draw UI
        terminal.draw(|f| {
            let main_chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(3),
                    Constraint::Length(if composing { 3 } else { 1 }),
                ])
                .split(f.area());

            let chunks = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(70),
                    Constraint::Percentage(30),
                ])
                .split(main_chunks[0]);

            // Message list (live-tail, scrollable)
            f.render_widget(&messages, chunks[0]);

            // Roster rail
            f.render_widget(&roster, chunks[1]);

            // Footer / compose bar
            if composing {
                let prompt = format!("Compose (Esc=cancel, Enter=send): {}", compose_buf);
                let bar = ratatui::widgets::Paragraph::new(prompt)
                    .block(ratatui::widgets::Block::default().borders(ratatui::widgets::Borders::TOP));
                f.render_widget(bar, main_chunks[1]);
            } else {
                let footer = format!(
                    "q:quit  a:compose  Tab:focus[{}]  j/k:nav  r:refresh",
                    focus_labels[focus as usize]
                );
                let bar = ratatui::widgets::Paragraph::new(footer)
                    .block(ratatui::widgets::Block::default().borders(ratatui::widgets::Borders::TOP));
                f.render_widget(bar, main_chunks[1]);
            }
        })?;

        // Handle input
        if event::poll(std::time::Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    if composing {
                        match key.code {
                            KeyCode::Esc => { composing = false; compose_buf.clear(); }
                            KeyCode::Enter => {
                                if !compose_buf.trim().is_empty() {
                                    // Shell out to stitchpad say; STITCHPAD_NAME comes from env
                                    let _ = std::process::Command::new("stitchpad")
                                        .arg("say")
                                        .arg(&compose_buf)
                                        .status();
                                    compose_buf.clear();
                                    composing = false;
                                    messages.refresh();
                                }
                            }
                            KeyCode::Backspace => { compose_buf.pop(); }
                            KeyCode::Char(c) => compose_buf.push(c),
                            _ => {}
                        }
                    } else {
                        match key.code {
                            KeyCode::Char('q') => break,
                            KeyCode::Char('a') => { composing = true; compose_buf.clear(); }
                            KeyCode::Tab => focus = (focus + 1) % focus_labels.len() as u8,
                            KeyCode::BackTab => focus = (focus + focus_labels.len() as u8 - 1) % focus_labels.len() as u8,
                            KeyCode::Char('j') => if focus == 0 { roster.next() } else { messages.scroll_down() },
                            KeyCode::Char('k') => if focus == 0 { roster.previous() } else { messages.scroll_up() },
                            KeyCode::Up => messages.scroll_up(),
                            KeyCode::Down => messages.scroll_down(),
                            KeyCode::PageUp => for _ in 0..10 { messages.scroll_up() },
                            KeyCode::PageDown => for _ in 0..10 { messages.scroll_down() },
                            KeyCode::Char('r') => { roster.refresh(); messages.refresh(); }
                            _ => {}
                        }
                    }
                }
            }
        }
    }

    // Restore terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    Ok(())
}
