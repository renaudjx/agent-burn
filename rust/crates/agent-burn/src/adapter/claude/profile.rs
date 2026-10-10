//! The Claude Code profile (config directory) whose sign-in Agent Burn reads.
//!
//! Claude Code keeps one login per `CLAUDE_CONFIG_DIR`. The default profile
//! lives in `~/.claude`, with the Keychain service `Claude Code-credentials`.
//! Any other profile keeps its own files in its directory and its own Keychain
//! service, suffixed with the first 8 hex digits of the SHA-256 of that
//! directory. With several directories listed, the first one is the profile
//! whose limits are read.

use std::{
    env,
    path::{Path, PathBuf},
};

use super::paths::normalize_claude_config_path;
use crate::home;

#[cfg(target_os = "macos")]
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Profile {
    dir: PathBuf,
    default_dir: PathBuf,
    explicit: bool,
}

impl Profile {
    pub(super) fn current() -> Option<Self> {
        Some(Self::resolve(
            env::var("CLAUDE_CONFIG_DIR").ok().as_deref(),
            home::home_dir()?,
        ))
    }

    fn resolve(configured: Option<&str>, home: PathBuf) -> Self {
        let default_dir = home.join(".claude");
        let first = configured.and_then(|list| {
            list.split(',')
                .map(str::trim)
                .find(|entry| !entry.is_empty())
        });
        match first {
            Some(raw) => Self {
                dir: normalize_claude_config_path(raw),
                default_dir,
                explicit: true,
            },
            None => Self {
                dir: default_dir.clone(),
                default_dir,
                explicit: false,
            },
        }
    }

    pub(super) fn dir(&self) -> &Path {
        &self.dir
    }

    fn is_default(&self) -> bool {
        self.dir == self.default_dir
    }

    /// Short stable id of a non-default profile, `None` for the default one.
    pub(super) fn id(&self) -> Option<String> {
        (!self.is_default()).then(|| short_hash(&self.dir))
    }

    pub(super) fn credentials_file(&self) -> PathBuf {
        self.dir.join(".credentials.json")
    }

    /// Claude Code's state file, which caches the usage it last read.
    pub(super) fn state_file(&self) -> Option<PathBuf> {
        if self.explicit && !self.is_default() {
            return Some(self.dir.join(".claude.json"));
        }
        Some(self.default_dir.parent()?.join(".claude.json"))
    }

    /// Keychain services holding this profile's sign-in, in lookup order. A
    /// custom profile never falls back to the default item, which belongs to
    /// another login. Naming the default directory explicitly may or may not
    /// have produced a suffixed item, so both are tried.
    #[cfg(target_os = "macos")]
    pub(super) fn keychain_services(&self) -> Vec<String> {
        if !self.explicit {
            return vec![KEYCHAIN_SERVICE.to_string()];
        }
        let suffixed = format!("{KEYCHAIN_SERVICE}-{}", short_hash(&self.dir));
        if self.is_default() {
            vec![suffixed, KEYCHAIN_SERVICE.to_string()]
        } else {
            vec![suffixed]
        }
    }
}

fn short_hash(dir: &Path) -> String {
    sha256_hex(dir.to_string_lossy().as_bytes())[..8].to_string()
}

/// Lowercase hex SHA-256, enough to name a profile the way Claude Code does.
fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&(data.len() as u64 * 8).to_be_bytes());
    for block in message.chunks_exact(64) {
        let mut w = [0u32; 64];
        for (slot, bytes) in w.iter_mut().zip(block.chunks_exact(4)) {
            *slot = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ (!e & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(choice)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }
    state.iter().map(|word| format!("{word:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(configured: Option<&str>) -> Profile {
        Profile::resolve(configured, PathBuf::from("/home/alice"))
    }

    #[test]
    fn sha256_matches_the_reference_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn no_configured_directory_is_the_default_profile() {
        let default = profile(None);
        assert_eq!(default.dir(), Path::new("/home/alice/.claude"));
        assert_eq!(default.id(), None);
        assert_eq!(
            default.credentials_file(),
            PathBuf::from("/home/alice/.claude/.credentials.json")
        );
        assert_eq!(
            default.state_file(),
            Some(PathBuf::from("/home/alice/.claude.json"))
        );
        assert_eq!(profile(Some("  ")), default);
    }

    #[test]
    fn a_custom_directory_has_its_own_id_files_and_state() {
        let work = profile(Some("/home/alice/.claude-work"));
        assert_eq!(work.id().as_deref(), Some("f0fc2950"));
        assert_eq!(
            work.credentials_file(),
            PathBuf::from("/home/alice/.claude-work/.credentials.json")
        );
        assert_eq!(
            work.state_file(),
            Some(PathBuf::from("/home/alice/.claude-work/.claude.json"))
        );
        assert_eq!(
            profile(Some("/home/alice/.claude-personal"))
                .id()
                .as_deref(),
            Some("37d3c5f5")
        );
    }

    #[test]
    fn the_first_listed_directory_is_the_profile() {
        let listed = profile(Some(
            " , /home/alice/.claude-work,/home/alice/.claude-personal",
        ));
        assert_eq!(listed.dir(), Path::new("/home/alice/.claude-work"));
    }

    #[test]
    fn naming_the_default_directory_keeps_the_default_profile() {
        let named = profile(Some("/home/alice/.claude"));
        assert_eq!(named.id(), None);
        assert_eq!(
            named.state_file(),
            Some(PathBuf::from("/home/alice/.claude.json"))
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn keychain_service_is_suffixed_only_for_a_custom_profile() {
        assert_eq!(
            profile(None).keychain_services(),
            ["Claude Code-credentials"]
        );
        assert_eq!(
            profile(Some("/home/alice/.claude-work")).keychain_services(),
            ["Claude Code-credentials-f0fc2950"]
        );
        assert_eq!(
            profile(Some("/home/alice/.claude")).keychain_services(),
            [
                "Claude Code-credentials-6952bbe3".to_string(),
                "Claude Code-credentials".to_string()
            ]
        );
    }
}
