#!/usr/bin/env python3
"""Let iloader place the pairing file into SideStore builds whose display name is
"SideStore Watch" (iloader matches apps by CFBundleDisplayName). Run from the iloader root."""
import pathlib
import sys

p = pathlib.Path("src-tauri/src/pairing.rs")
text = p.read_text()
old = """            .ok_or(AppError::Misc("Failed to parse installed apps".to_string()))?;

        if PAIRING_APPS.iter().any(|(name, _)| name == &n) {"""
new = """            .ok_or(AppError::Misc("Failed to parse installed apps".to_string()))?;
        // Sage patch: the SideStore Watch build is SideStore under another name.
        let n = if n == "SideStore Watch" { "SideStore" } else { n };

        if PAIRING_APPS.iter().any(|(name, _)| name == &n) {"""
if text.count(old) != 1:
    sys.exit(f"patch_iloader.py: anchor found {text.count(old)} times")
p.write_text(text.replace(old, new))
print("patched", p)
