#[path = "../../../src/hx_data_mode.rs"]
mod hx_data_mode;

fn main() {
    let low = hx_data_mode::network_is_low_data();
    let mode = hx_data_mode::want_mode();
    let mut config = hbb_common::config::PeerConfig::default();
    hx_data_mode::apply(&mut config, mode);
    println!(
        "low data: {low}, mode: {:?}, quality: {:?}, applied: {:?}",
        mode, config.custom_image_quality, config.options
    );
    for m in [
        hx_data_mode::Mode::Low,
        hx_data_mode::Mode::High,
        hx_data_mode::Mode::Ultra,
    ] {
        let mut c = hbb_common::config::PeerConfig::default();
        hx_data_mode::apply(&mut c, m);
        println!("{:?}: quality {:?}, {:?}", m, c.custom_image_quality, c.options);
    }
}
