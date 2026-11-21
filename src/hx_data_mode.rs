//! HX Remote data mode (261121): pick image settings for the network this computer is on.
//!
//! - low  (저데이터): phone hotspot, a network marked "Low Data Mode" (macOS) or a metered
//!   connection (Windows) — 10% quality, 5 fps,
//!   4:2:0, no audio. Keeps a remote screen usable at well under 1 Mbps.
//! - high (고데이터): everything else — 50% quality, 20 fps, 4:4:4, audio on.
//!
//! Local option `hx-data-mode`: "" or "auto" (default) picks by network at connect time,
//! "low" / "high" pins one. The mode applied to a peer is kept in the peer option
//! `hx-data-mode-now`, which the toolbar reads to show the current choice.
//! The toolbar can switch a running session (flutter/lib/common/widgets/toolbar.dart).

use hbb_common::{
    config::{LocalConfig, PeerConfig},
    log,
};

pub const OPTION_MODE: &str = "hx-data-mode";
pub const PEER_OPTION_NOW: &str = "hx-data-mode-now";

pub struct Preset {
    pub quality: i32,
    pub fps: i32,
    pub i444: bool,
    pub audio: bool,
}

pub const LOW: Preset = Preset {
    quality: 10,
    fps: 5,
    i444: false,
    audio: false,
};

pub const HIGH: Preset = Preset {
    quality: 50,
    fps: 20,
    i444: true,
    audio: true,
};

/// Decide the mode for a new remote-desktop session: true = low data.
pub fn want_low_data() -> bool {
    match LocalConfig::get_option(OPTION_MODE).as_str() {
        "low" => true,
        "high" => false,
        _ => network_is_low_data(),
    }
}

/// Write the preset into the peer config so every existing code path
/// (option message, codec choice, toolbar menus) sees it.
pub fn apply(config: &mut PeerConfig, low: bool) {
    let p = if low { &LOW } else { &HIGH };
    config.image_quality = "custom".to_owned();
    config.custom_image_quality = vec![p.quality];
    config
        .options
        .insert("custom-fps".to_owned(), p.fps.to_string());
    if p.i444 {
        config.options.insert("i444".to_owned(), "Y".to_owned());
    } else {
        config.options.remove("i444");
    }
    config.disable_audio.v = !p.audio;
    config.options.insert(
        PEER_OPTION_NOW.to_owned(),
        if low { "low" } else { "high" }.to_owned(),
    );
}

/// Called when a remote-desktop session starts.
pub fn apply_on_connect(id: &str, config: &mut PeerConfig) {
    let low = want_low_data();
    apply(config, low);
    config.store(id);
    log::info!(
        "HX data mode for {}: {} (setting '{}')",
        id,
        if low { "low" } else { "high" },
        LocalConfig::get_option(OPTION_MODE)
    );
}

/// True when the current network is a phone hotspot / metered link or the user
/// turned on "Low Data Mode" for it (macOS: NWPath isExpensive / isConstrained).
#[cfg(target_os = "macos")]
pub fn network_is_low_data() -> bool {
    mac::current_path_flags()
        .map(|(expensive, constrained)| expensive || constrained)
        .unwrap_or(false)
}

/// True when Windows reports the current internet connection as metered (a phone
/// hotspot Windows recognises, mobile broadband, or "Set as metered connection" turned
/// on for this Wi-Fi), roaming or over its data limit.
#[cfg(target_os = "windows")]
pub fn network_is_low_data() -> bool {
    // COM in its own thread so the caller's apartment does not matter.
    match std::thread::spawn(windows_connection_cost).join() {
        Ok(Ok(cost)) => {
            use windows::Win32::Networking::NetworkListManager::{
                NLM_CONNECTION_COST_FIXED, NLM_CONNECTION_COST_OVERDATALIMIT,
                NLM_CONNECTION_COST_ROAMING, NLM_CONNECTION_COST_VARIABLE,
            };
            let low_mask = NLM_CONNECTION_COST_FIXED.0
                | NLM_CONNECTION_COST_VARIABLE.0
                | NLM_CONNECTION_COST_ROAMING.0
                | NLM_CONNECTION_COST_OVERDATALIMIT.0;
            log::info!("HX data mode: connection cost = 0x{:x}", cost);
            cost as i32 & low_mask != 0
        }
        Ok(Err(e)) => {
            log::warn!("HX data mode: connection cost unavailable: {}", e);
            false
        }
        Err(_) => false,
    }
}

#[cfg(target_os = "windows")]
fn windows_connection_cost() -> windows::core::Result<u32> {
    use windows::Win32::{
        Networking::NetworkListManager::{INetworkCostManager, NetworkListManager},
        System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED},
    };
    unsafe {
        let init = CoInitializeEx(None, COINIT_MULTITHREADED);
        let result: windows::core::Result<u32> = (|| {
            let manager: INetworkCostManager =
                CoCreateInstance(&NetworkListManager, None, CLSCTX_ALL)?;
            let mut cost = 0u32;
            manager.GetCost(&mut cost, std::ptr::null())?;
            Ok(cost)
        })();
        if init.is_ok() {
            CoUninitialize();
        }
        result
    }
}

/// Linux: no detection — auto means high; pick low from the toolbar.
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn network_is_low_data() -> bool {
    false
}

#[cfg(target_os = "macos")]
mod mac {
    use block::ConcreteBlock;
    use hbb_common::log;
    use std::{ffi::c_void, sync::mpsc, time::Duration};

    type NwObj = *mut c_void;

    #[link(name = "Network", kind = "framework")]
    extern "C" {
        fn nw_path_monitor_create() -> NwObj;
        fn nw_path_monitor_set_queue(monitor: NwObj, queue: *mut c_void);
        fn nw_path_monitor_set_update_handler(monitor: NwObj, handler: *const c_void);
        fn nw_path_monitor_start(monitor: NwObj);
        fn nw_path_monitor_cancel(monitor: NwObj);
        fn nw_path_is_expensive(path: NwObj) -> bool;
        fn nw_path_is_constrained(path: NwObj) -> bool;
        fn nw_release(obj: *mut c_void);
    }

    extern "C" {
        fn dispatch_queue_create(label: *const std::os::raw::c_char, attr: *mut c_void)
            -> *mut c_void;
        fn dispatch_release(obj: *mut c_void);
    }

    /// (expensive, constrained) of the current default path, or None if it did not
    /// answer within a second.
    pub fn current_path_flags() -> Option<(bool, bool)> {
        let (tx, rx) = mpsc::sync_channel::<(bool, bool)>(1);
        unsafe {
            let monitor = nw_path_monitor_create();
            if monitor.is_null() {
                return None;
            }
            let queue = dispatch_queue_create(
                b"com.hydroxpand.hxremote.netpath\0".as_ptr() as _,
                std::ptr::null_mut(),
            );
            let handler = ConcreteBlock::new(move |path: NwObj| {
                let flags = (nw_path_is_expensive(path), nw_path_is_constrained(path));
                let _ = tx.try_send(flags);
            })
            .copy();
            nw_path_monitor_set_queue(monitor, queue);
            nw_path_monitor_set_update_handler(monitor, &*handler as *const _ as *const c_void);
            nw_path_monitor_start(monitor);
            let r = rx.recv_timeout(Duration::from_secs(1)).ok();
            nw_path_monitor_cancel(monitor);
            nw_release(monitor);
            // The queue may still run the (cancelled) handler once; keep the block alive
            // until the queue is gone by leaking it — a few bytes per session start.
            std::mem::forget(handler);
            dispatch_release(queue);
            log::info!("HX data mode: network path (expensive, constrained) = {:?}", r);
            r
        }
    }
}
