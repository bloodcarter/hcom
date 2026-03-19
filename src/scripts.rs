/// Bundled scripts embedded at compile time.
pub const SCRIPTS: &[(&str, &str)] = &[
    ("confess", include_str!("scripts/bundled/confess.sh")),
    ("debate", include_str!("scripts/bundled/debate.sh")),
    ("fatcow", include_str!("scripts/bundled/fatcow.sh")),
    ("plan-execute", include_str!("scripts/bundled/plan-execute.sh")),
    ("plan-review", include_str!("scripts/bundled/plan-review.sh")),
];
