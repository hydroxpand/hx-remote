//! Stand-in for the parts of hbb_common that src/hx_data_mode.rs uses.
pub use log;

pub mod config {
    use std::collections::HashMap;

    #[derive(Default, Debug)]
    pub struct DisableAudio {
        pub v: bool,
    }

    #[derive(Default, Debug)]
    pub struct PeerConfig {
        pub image_quality: String,
        pub custom_image_quality: Vec<i32>,
        pub disable_audio: DisableAudio,
        pub options: HashMap<String, String>,
    }

    impl PeerConfig {
        pub fn store(&self, _id: &str) {}
    }

    pub struct LocalConfig;

    impl LocalConfig {
        pub fn get_option(_k: &str) -> String {
            String::new()
        }
    }
}
