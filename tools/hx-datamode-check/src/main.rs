#[path = "../../../src/hx_data_mode.rs"]
mod hx_data_mode;

fn main() {
    let low = hx_data_mode::network_is_low_data();
    let mut config = hbb_common::config::PeerConfig::default();
    hx_data_mode::apply(&mut config, low);
    println!("low data: {low}, applied: {:?}", config.options);
}
